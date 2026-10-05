import XCTest
import AppKit
import CoreImage
import CoreVideo
import Metal
@testable import VoiceInput

final class BackdropPerformanceTests: XCTestCase {
    private let context = CIContext(options: [.cacheIntermediates: false])
    private var output: URL? {
        ProcessInfo.processInfo.environment["VOICEINPUT_PERF_OUTPUT"].map { URL(fileURLWithPath: $0, isDirectory: true) }
    }
    private func buffer(width: Int = 1600, height: Int = 500, phase: Int = 0,
                        format: OSType = kCVPixelFormatType_32BGRA) throws -> CVPixelBuffer {
        var created: CVPixelBuffer?
        let attributes = [kCVPixelBufferIOSurfacePropertiesKey: [:], kCVPixelBufferMetalCompatibilityKey: true] as CFDictionary
        XCTAssertEqual(CVPixelBufferCreate(kCFAllocatorDefault, width, height, format, attributes, &created), kCVReturnSuccess)
        let result = try XCTUnwrap(created)
        CVBufferSetAttachment(result, kCVImageBufferCGColorSpaceKey, CGColorSpace(name: CGColorSpace.sRGB)!, .shouldPropagate)
        CVPixelBufferLockBaseAddress(result, [])
        defer { CVPixelBufferUnlockBaseAddress(result, []) }
        let bytes = try XCTUnwrap(CVPixelBufferGetBaseAddress(result)).assumingMemoryBound(to: UInt8.self)
        let stride = CVPixelBufferGetBytesPerRow(result)
        for y in 0..<height {
            for x in 0..<width {
                let i = y * stride + x * 4
                // Deliberately asymmetric vertical/color markers reveal flipping,
                // wrong channel order, color-space drift and stale buffers.
                let r = UInt8((x * 215 / width + phase * 13) % 256)
                let g = UInt8(y * 239 / height)
                let b = UInt8((x / 31 + y / 19) % 2 == 0 ? 43 : 189)
                if format == kCVPixelFormatType_32BGRA {
                    bytes[i] = b; bytes[i+1] = g; bytes[i+2] = r; bytes[i+3] = 255
                } else {
                    bytes[i] = 255; bytes[i+1] = r; bytes[i+2] = g; bytes[i+3] = b
                }
            }
        }
        return result
    }
    private func write(_ image: CGImage, name: String) throws {
        guard let output else { return }
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        try XCTUnwrap(NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]))
            .write(to: output.appendingPathComponent(name))
    }
    private func write(_ dictionary: [String: Any], name: String) throws {
        guard let output else { return }
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: dictionary, options: [.prettyPrinted, .sortedKeys])
            .write(to: output.appendingPathComponent(name))
    }
    func testDirectSurfaceMatchesImagePathColorOrientationAndRefraction() throws {
        let renderer = try SiriMetalRenderer()
        let buffer = try buffer()
        let frame = CapsuleBackdropFrame.pixelBuffer(buffer)
        let image = try XCTUnwrap(frame.image(using: context))
        let rect = CGRect(x: -270, y: -20, width: 800, height: 250)
        var results = [[String: Any]]()
        for (name, progress, energy) in [("opening", Float(0.18), Float(0)), ("quiet", 1, 0), ("speaking", 1, 0.8)] {
            renderer.progress = progress; renderer.intro = 1.5; renderer.energy = energy; renderer.elapsed = 2.5
            renderer.setBackground(image, rect: rect)
            let before = try renderer.snapshot(size: CGSize(width: 260, height: 180))
            renderer.setBackground(frame, rect: rect)
            XCTAssertTrue(renderer.usesPixelBufferBackground, "BGRA must actually map; fallback would hide a broken fast path")
            let after = try renderer.snapshot(size: CGSize(width: 260, height: 180))
            let a = Array(before.dataProvider!.data! as Data), b = Array(after.dataProvider!.data! as Data)
            XCTAssertEqual(a.count, b.count)
            var difference = 0, maximum = 0, alphaMismatch = 0
            for i in a.indices {
                let d = abs(Int(a[i]) - Int(b[i]))
                if i % 4 == 3 { if d != 0 { alphaMismatch += 1 } }
                else { difference += d; maximum = max(maximum, d) }
            }
            let mean = Double(difference) / Double(a.count / 4 * 3)
            XCTAssertEqual(alphaMismatch, 0, "Shape/transparent edges must remain identical")
            XCTAssertLessThanOrEqual(mean, 0.5, "Must preserve vertical direction, BGRA channels and sRGB appearance")
            XCTAssertLessThanOrEqual(maximum, 3)
            results.append(["state":name,"mean_channel_difference":mean,"maximum_channel_difference":maximum,"alpha_mismatches":alphaMismatch])
            try write(before, name: "\(name)-before.png"); try write(after, name: "\(name)-after.png")
        }
        renderer.setBackground(nil)
        XCTAssertFalse(renderer.usesPixelBufferBackground)
        try write(["comparisons":results,"background_pixels":[1600,500],"render_pixels":[520,360]], name: "visual-equivalence.json")
    }
    func testUnsupportedFormatFallsBackAndReplacementNeverUsesPreviousFrame() throws {
        let renderer = try SiriMetalRenderer()
        renderer.progress = 1; renderer.intro = 1.5; renderer.energy = 0.5; renderer.elapsed = 1.8
        let rect = CGRect(x: 0, y: 0, width: 260, height: 180)
        var previous: Data?
        for i in 0..<12 {
            let frame = CapsuleBackdropFrame.pixelBuffer(try buffer(width: 520, height: 360, phase: i))
            renderer.setBackground(frame, rect: rect)
            XCTAssertTrue(renderer.usesPixelBufferBackground)
            let data = try renderer.snapshot(size: rect.size).dataProvider!.data! as Data
            if let previous { XCTAssertNotEqual(previous, data, "Frame replacement must update sampled surface") }
            previous = data
        }
        let fallback = CapsuleBackdropFrame.pixelBuffer(try buffer(width: 520, height: 360, format: kCVPixelFormatType_32ARGB))
        renderer.setBackground(fallback, rect: rect)
        XCTAssertFalse(renderer.usesPixelBufferBackground)
        let actual = try renderer.snapshot(size: rect.size).dataProvider!.data! as Data
        renderer.setBackground(try XCTUnwrap(fallback.image(using: context)), rect: rect)
        let expected = try renderer.snapshot(size: rect.size).dataProvider!.data! as Data
        XCTAssertEqual(actual, expected, "Unsupported input must retain the working image fallback")
    }
    func testPixelBackdropCanSwitchBetweenSiriAndClassicWithoutNewCapture() throws {
        _ = NSApplication.shared
        let view = RecordingCapsuleView(frame: CGRect(x: 0, y: 0, width: 338, height: 180))
        defer { view.stopAnimation(); view.setRefractionBackground(nil) }
        let frame = CapsuleBackdropFrame.pixelBuffer(try buffer())
        view.applyAppearance(OverlayAppearance(visualStyle: 1, refraction: true))
        view.setRefractionBackground(frame, rect: CGRect(x: -231, y: -20, width: 800, height: 250))
        XCTAssertTrue(view.usesPixelBufferBackdrop)
        view.applyAppearance(OverlayAppearance(visualStyle: 0, refraction: true))
        XCTAssertFalse(view.usesSiriPresentation)
        let ready = expectation(description: "Classic CPU refraction still composes mapped capture")
        let deadline = Date().addingTimeInterval(1)
        func inspect() {
            let composed = view.layer?.sublayers?.contains(where: { layer in
                guard let contents = layer.contents else { return false }
                return CFGetTypeID(contents as CFTypeRef) == CGImage.typeID && !layer.isHidden
            }) ?? false
            if composed || Date() >= deadline { XCTAssertTrue(composed); ready.fulfill() }
            else { DispatchQueue.main.asyncAfter(deadline: .now()+0.02, execute: inspect) }
        }
        inspect(); wait(for: [ready], timeout: 1.5)
        view.applyAppearance(OverlayAppearance(visualStyle: 1, refraction: true))
        XCTAssertTrue(view.usesPixelBufferBackdrop, "Switch back must reuse the current frame, not wait for another capture")
        view.setRefractionBackground(nil)
        XCTAssertFalse(view.usesPixelBufferBackdrop)
    }

    func testMailboxDropsOldFramesAndStopDrainsPendingDelivery() {
        let mailbox = LatestBackdropMailbox<Int>()
        XCTAssertTrue(mailbox.offer(1))
        for i in 2...100 { XCTAssertFalse(mailbox.offer(i)) }
        XCTAssertEqual(mailbox.take(),100)
        XCTAssertNil(mailbox.take())
        XCTAssertTrue(mailbox.offer(101)); mailbox.clear()
        XCTAssertFalse(mailbox.offer(102), "Reuse existing scheduled callback after stop/start")
        XCTAssertEqual(mailbox.take(),102)
        XCTAssertTrue(mailbox.offer(103)); mailbox.clear()
        XCTAssertNil(mailbox.take())
        XCTAssertTrue(mailbox.offer(104)); XCTAssertEqual(mailbox.take(),104)
    }
    func testBackgroundPreparationBenchmark() throws {
        let renderer = try SiriMetalRenderer()
        let buffers = try (0..<6).map { try buffer(phase: $0) }
        let rect = CGRect(x: -270, y: -20, width: 800, height: 250)
        func measure(direct: Bool, count: Int) throws -> [Double] {
            var times = [Double]()
            for i in 0..<count {
                try autoreleasepool {
                    let frame = CapsuleBackdropFrame.pixelBuffer(buffers[i % buffers.count])
                    let started = CACurrentMediaTime()
                    if direct { renderer.setBackground(frame, rect: rect) }
                    else { renderer.setBackground(try XCTUnwrap(frame.image(using: context)), rect: rect) }
                    times.append((CACurrentMediaTime() - started) * 1000)
                    if direct { XCTAssertTrue(renderer.usesPixelBufferBackground) }
                }
            }
            return times
        }
        _ = try measure(direct: false, count: 12); _ = try measure(direct: true, count: 12)
        var before = [Double](), after = [Double]()
        // Alternate batches so warmup/system-load drift is not assigned to one path.
        for i in 0..<6 {
            if i % 2 == 0 { before += try measure(direct: false,count: 40); after += try measure(direct: true,count: 40) }
            else { after += try measure(direct: true,count: 40); before += try measure(direct: false,count: 40) }
        }
        func summary(_ values: [Double]) -> [String: Any] {
            let sorted=values.sorted()
            return ["count":values.count,"mean_ms":values.reduce(0,+)/Double(values.count),"p50_ms":sorted[values.count/2],"p95_ms":sorted[Int(Double(values.count-1)*0.95)],"max_ms":sorted.last!]
        }
        var gpuBefore = [Double](), gpuAfter = [Double]()
        renderer.progress=1;renderer.intro=1.5;renderer.energy=0.7;renderer.elapsed=2.5
        let frame=CapsuleBackdropFrame.pixelBuffer(buffers[0]); let image=try XCTUnwrap(frame.image(using: context))
        for i in 0..<40 {
            renderer.setBackground(image, rect:rect)
            _ = try renderer.snapshot(size:CGSize(width:260,height:180))
            if i>=5 { gpuBefore.append(renderer.lastSnapshotGPUTime*1000) }
            renderer.setBackground(frame,rect:rect)
            _ = try renderer.snapshot(size:CGSize(width:260,height:180))
            if i>=5 { gpuAfter.append(renderer.lastSnapshotGPUTime*1000) }
        }
        let reduction=1-(after.reduce(0,+)/Double(after.count))/(before.reduce(0,+)/Double(before.count))
        let result:[String:Any]=["scope":"1600x500 background preparation only; synthetic IOSurface buffers; no live capture, recognition or battery measurement", "image_conversion_upload":summary(before),"direct_surface_mapping":summary(after),"preparation_wall_time_reduction":reduction,"same_shader_gpu_before":summary(gpuBefore),"same_shader_gpu_after":summary(gpuAfter)]
        try write(result,name:"background-benchmark.json")
        print("BACKDROP_BENCHMARK",result)
    }
}
