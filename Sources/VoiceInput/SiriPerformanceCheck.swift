import AppKit
import CoreImage
import CoreVideo
import Darwin

// Developer-only comparison. No microphone, key monitor, desktop capture,
// recognition, authorization request or settings write is started here.
@available(macOS 26.0, *)
final class SiriPerformanceCheck {
    private let mode: String
    private let output: URL
    private let window: NSWindow
    private let backdrop: NSImageView
    private let siri: SiriGlassView?
    private let native: NSGlassEffectView?
    private let buffers: [CVPixelBuffer]
    private let images: [NSImage]
    private let context = CIContext(options: [.cacheIntermediates: false])
    private var timer: Timer?
    private var startTime: CFTimeInterval = 0
    private var markTime: CFTimeInterval = 0
    private var markCPU: Double = 0
    private var stage = 0
    private var frame = 0
    private var markFrame = 0
    private var markRender = 0
    private var samples = [[String: Any]]()
    private let backgroundRect = CGRect(x: -270, y: -35, width: 800, height: 250)

    init(mode: String, output: URL) throws {
        guard ["image", "direct", "native"].contains(mode) else { throw NSError(domain: "SiriBenchmark", code: 1) }
        self.mode = mode; self.output = output
        let context = CIContext(options: [.cacheIntermediates: false])
        var buffers = [CVPixelBuffer](), images = [NSImage]()
        for phase in 0..<6 {
            var created: CVPixelBuffer?
            let attributes = [kCVPixelBufferIOSurfacePropertiesKey: [:], kCVPixelBufferMetalCompatibilityKey: true] as CFDictionary
            guard CVPixelBufferCreate(kCFAllocatorDefault, 1600, 500, kCVPixelFormatType_32BGRA, attributes, &created) == kCVReturnSuccess,
                  let buffer = created else { throw NSError(domain: "SiriBenchmark", code: 2) }
            CVBufferSetAttachment(buffer, kCVImageBufferCGColorSpaceKey, CGColorSpace(name: CGColorSpace.sRGB)!, .shouldPropagate)
            CVPixelBufferLockBaseAddress(buffer, [])
            let bytes = CVPixelBufferGetBaseAddress(buffer)!.assumingMemoryBound(to: UInt8.self)
            let stride = CVPixelBufferGetBytesPerRow(buffer)
            for y in 0..<500 { for x in 0..<1600 {
                let i = y * stride + x * 4
                bytes[i] = UInt8((x / 80 + y / 45 + phase) % 2 == 0 ? 56 : 155)
                bytes[i+1] = UInt8(y * 210 / 500)
                bytes[i+2] = UInt8((x * 195 / 1600 + phase * 10) % 256)
                bytes[i+3] = 255
            }}
            CVPixelBufferUnlockBaseAddress(buffer, [])
            guard let image = CapsuleBackdropFrame.pixelBuffer(buffer).image(using: context) else { throw NSError(domain: "SiriBenchmark", code: 3) }
            buffers.append(buffer); images.append(NSImage(cgImage: image, size: CGSize(width: 800, height: 250)))
        }
        self.buffers = buffers; self.images = images
        window = NSWindow(contentRect: CGRect(x: 100, y: 100, width: 800, height: 250),
                          styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "VoiceInput 性能对照 · 不录音 · 自动关闭"
        window.isReleasedWhenClosed = false
        backdrop = NSImageView(frame: CGRect(x: 0, y: 0, width: 800, height: 250))
        backdrop.imageScaling = .scaleAxesIndependently
        backdrop.image = images[0]
        window.contentView!.addSubview(backdrop)
        if mode == "native" {
            siri = nil
            let glass = NSGlassEffectView(frame: CGRect(x: 323.44, y: 64, width: 153.12, height: 118.44))
            glass.style = .clear; glass.cornerRadius = 59.22
            glass.isHidden = true
            window.contentView!.addSubview(glass); native = glass
        } else {
            native = nil
            let view = try SiriGlassView(renderingFrame: CGRect(x: 270, y: 35, width: 260, height: 180))
            view.apply(glass: 0, refraction: 10.37539308176101, gain: 2)
            view.isHidden = true
            window.contentView!.addSubview(view); siri = view
        }
    }
    private func cpuTime() -> Double {
        var usage = rusage()
        getrusage(RUSAGE_SELF, &usage)
        return Double(usage.ru_utime.tv_sec + usage.ru_stime.tv_sec)
            + Double(usage.ru_utime.tv_usec + usage.ru_stime.tv_usec) / 1_000_000
    }
    func run() {
        window.center(); window.orderFrontRegardless()
        startTime = CACurrentMediaTime(); markTime = startTime; markCPU = cpuTime()
        timer = Timer(timeInterval: 1.0 / 30, repeats: true) { [weak self] _ in self?.step() }
        RunLoop.main.add(timer!, forMode: .common)
    }
    private func mark(_ name: String) {
        let now = CACurrentMediaTime(), cpu = cpuTime(), seconds = now - markTime
        samples.append(["phase": name, "duration_seconds": seconds, "process_cpu_seconds": cpu-markCPU,
                        "process_cpu_percent_one_core": (cpu-markCPU)/seconds*100,
                        "background_updates_per_second": Double(frame-markFrame)/seconds,
                        "siri_draw_callbacks_per_second": Double((siri?.renderedFrameCount ?? 0)-markRender)/seconds,
                        "window_visible": window.isVisible])
        markTime = now; markCPU = cpu; markFrame = frame; markRender = siri?.renderedFrameCount ?? 0
    }
    private func step() {
        frame += 1
        let index = frame % buffers.count
        backdrop.image = images[index]
        if stage == 1 || stage == 2 {
            let input = CapsuleBackdropFrame.pixelBuffer(buffers[index])
            if mode == "image" { siri?.setBackground(input.image(using: context), rect: backgroundRect) }
            if mode == "direct" { siri?.setBackground(input, rect: backgroundRect) }
            siri?.setLevel(Float(max(0.05, 0.5 + sin(Double(frame) * 0.143) * 0.35)))
        }
        let elapsed = CACurrentMediaTime() - startTime
        if stage == 0 && elapsed >= 3 {
            mark("scene_only_before")
            stage = 1; siri?.isHidden = false; siri?.begin(); native?.isHidden = false
        } else if stage == 1 && elapsed >= 6 {
            mark("entrance_warmup")
            stage = 2
        } else if stage == 2 && elapsed >= 18 {
            mark("steady_visible")
            stage = 3; siri?.stop(); siri?.setBackground(nil); siri?.isHidden = true; native?.isHidden = true
        } else if stage == 3 && elapsed >= 21 {
            mark("scene_only_after")
            finish()
        }
    }
    private func finish() {
        timer?.invalidate(); timer = nil
        window.orderOut(nil)
        let record: [String: Any] = ["mode": mode, "background_pixels": [1600, 500], "capture_emulation_hz": 30,
            "siri_target_hz": mode == "native" ? 0 : 60, "glass_points": [153.12, 118.44], "samples": samples,
            "scope": "Synthetic scrolling scene. Local process CPU; excludes WindowServer GPU/power, real screen capture and speech. Native is stock clear glass without Siri's color wave; lower-cost material reference only."]
        do {
            try FileManager.default.createDirectory(at: output.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONSerialization.data(withJSONObject: record, options: [.prettyPrinted, .sortedKeys]).write(to: output)
            print("PASS: UI comparison written to \(output.path)")
            NSApplication.shared.terminate(nil)
        } catch { fputs("FAIL: \(error)\n", stderr); exit(1) }
    }
}
