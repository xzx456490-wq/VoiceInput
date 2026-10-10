import XCTest
import AppKit
import Metal
@testable import VoiceInput
final class SiriGlassTests: XCTestCase {
    func testSiriEntranceAndReleaseIgnoreLateAudio() {
        var motion = SiriMotion()
        motion.begin(); motion.setLevel(0.8)
        for _ in 0..<120 { motion.step(1.0/60) }
        XCTAssertEqual(motion.progress, 1, accuracy: 0.005)
        XCTAssertGreaterThan(motion.energy, 0.8)
        XCTAssertGreaterThan(motion.intro, 1)
        motion.end(); motion.setLevel(1)
        for _ in 0..<120 { motion.step(1.0/60) }
        XCTAssertTrue(motion.hasSettled)
        XCTAssertLessThan(motion.energy, 0.001)
        XCTAssertEqual(motion.lightOpacity, 0)
        XCTAssertEqual(motion.opacity, 0)
        motion.begin()
        XCTAssertEqual(motion.energy, 0)
        XCTAssertEqual(motion.progress, 0)
        motion.setLevel(.nan); motion.step(.infinity)
        XCTAssertEqual(motion.progress, 0)
    }
    func testColorLightFollowsApprovedExpansionWithoutAudio() throws {
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("Metal unavailable on this runner") }
        let renderer = try SiriMetalRenderer()
        var motion = SiriMotion(); motion.begin()
        XCTAssertGreaterThanOrEqual(motion.intro, 1.15, "彩光数据立即就绪，显示由展开时间控制")
        for frame in 1...54 {
            motion.step(1.0 / 60)
            guard [36, 42, 54].contains(frame) else { continue }
            renderer.presentationScale = Float(motion.presentationScale)
            renderer.lightOpacity = Float(motion.lightOpacity)
            renderer.progress = Float(motion.progress); renderer.intro = Float(motion.intro)
            renderer.energy = Float(motion.energy); renderer.elapsed = Float(motion.elapsed)
            let image = try renderer.snapshot(size: CGSize(width: 260, height: 180), scale: 1)
            let lit = Array(image.dataProvider!.data! as Data)
            renderer.lightOpacity = 0
            let darkImage = try renderer.snapshot(size: CGSize(width: 260, height: 180), scale: 1)
            let dark = Array(darkImage.dataProvider!.data! as Data)
            renderer.lightOpacity = Float(motion.lightOpacity)
            let colored = stride(from: 0, to: lit.count, by: 4).filter { offset in
                let channels = (0..<3).map { Int(lit[offset + $0]) }
                return channels.max()! - channels.min()! > 12
                    && (0..<3).contains { Int(lit[offset + $0]) > Int(dark[offset + $0]) + 12 }
            }.count
            XCTAssertGreaterThan(colored, 10, "第\(frame)帧应有真实彩色光，不依赖声音或背景采集")
            XCTAssertEqual(motion.energy, 0)
        }
        motion.end(); motion.step(1.0 / 60); motion.begin()
        XCTAssertGreaterThanOrEqual(motion.intro, 1.15, "再次开始时彩光数据仍已就绪")
    }
    func testSoftExitIsMonotonicAndDuplicateEndDoesNotRestartIt() {
        var motion = SiriMotion(); motion.begin(); motion.setLevel(0.8)
        for _ in 0..<120 { motion.step(1.0 / 60) }
        motion.end()
        XCTAssertFalse(motion.recording)
        var previous = motion.progress
        for frame in 0..<74 {
            if frame == 25 { motion.end() }
            motion.step(1.0 / 60)
            XCTAssertLessThanOrEqual(motion.progress, previous + 1e-9)
            XCTAssertGreaterThanOrEqual(motion.progress, 0)
            XCTAssertLessThan(abs(motion.progress - previous), 0.10)
            if frame == 24 { XCTAssertFalse(motion.hasSettled); XCTAssertGreaterThan(motion.opacity, 0.99) }
            previous = motion.progress
        }
        XCTAssertTrue(motion.hasSettled)
        XCTAssertEqual(motion.opacity, 0)
        motion.begin()
        XCTAssertTrue(motion.recording)
        XCTAssertEqual(motion.opacity, 1)
        XCTAssertEqual(motion.presentationScale, 0)
        XCTAssertEqual(motion.lightOpacity, 0)
        for _ in 0..<120 { motion.step(1.0 / 60) }
        XCTAssertGreaterThan(motion.progress, 0.99)
    }
    func testShortPressAndReducedMotionExit() {
        var motion = SiriMotion(); motion.begin(); motion.step(1.0 / 60); motion.end()
        for _ in 0..<74 { motion.step(1.0 / 60) }
        XCTAssertTrue(motion.hasSettled)
        XCTAssertEqual(motion.opacity, 0)
        motion.begin(); motion.step(1.0 / 60, reducedMotion: true); motion.end()
        motion.step(1.0 / 60, reducedMotion: true)
        XCTAssertTrue(motion.hasSettled)
        XCTAssertEqual(motion.opacity, 0)
    }
    func testRealMetalExitEndsCompletelyTransparent() throws {
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("Metal unavailable on this runner") }
        let renderer = try SiriMetalRenderer()
        var motion = SiriMotion(); motion.begin(); motion.setLevel(0.8)
        for _ in 0..<120 { motion.step(1.0 / 60) }
        motion.end()
        for _ in 0..<74 { motion.step(1.0 / 60) }
        renderer.presentationScale = Float(motion.presentationScale)
            renderer.lightOpacity = Float(motion.lightOpacity)
            renderer.progress = Float(motion.progress); renderer.intro = Float(motion.intro)
        renderer.energy = Float(motion.energy); renderer.elapsed = Float(motion.elapsed)
        renderer.exitLightScale = Float(motion.exitLightScale)
        renderer.lightOpacity = Float(motion.lightOpacity); renderer.opacity = Float(motion.opacity)
        let frame = try renderer.snapshot(size: CGSize(width: 260, height: 180), scale: 1)
        let bytes = Array(frame.dataProvider!.data! as Data)
        XCTAssertTrue(stride(from: 3, to: bytes.count, by: 4).allSatisfy { bytes[$0] == 0 }, "退场末尾不能留下黑色胶囊或亮边")
    }
    func testLateExitCannotHideReusedPanel() {
        _ = NSApplication.shared
        let panel = OverlayPanel()
        defer { panel.dismiss(); panel.stopBackdropCapture() }
        panel.show(text: "第一次")
        var oldCallbacks = 0
        panel.endRecordingPresentation { oldCallbacks += 1 }
        let restarted = expectation(description: "重新录音后旧退场不可隐藏新浮层")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            panel.show(text: "第二次")
            XCTAssertEqual(oldCallbacks, 1)
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.1) {
                XCTAssertTrue(panel.isVisible)
                XCTAssertTrue(panel.canBecomeKey)
                XCTAssertEqual(oldCallbacks, 1)
                restarted.fulfill()
            }
        }
        wait(for: [restarted], timeout: 3)
        let hidden = expectation(description: "第二次正常退场")
        panel.endRecordingPresentation {
            XCTAssertFalse(panel.isVisible)
            XCTAssertFalse(panel.canBecomeKey)
            hidden.fulfill()
        }
        wait(for: [hidden], timeout: 2.5)
    }
    func testRealMetalFramesRespondToSoundAndStayInsideGlass() throws {
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("Metal unavailable on this runner") }
        let renderer = try SiriMetalRenderer()
        renderer.progress = 1; renderer.intro = 2; renderer.elapsed = 2.5
        func bytes(_ energy: Float) throws -> [UInt8] {
            renderer.energy = energy
            let image = try renderer.snapshot(size: CGSize(width: 300, height: 200), scale: 1)
            return Array(image.dataProvider!.data! as Data)
        }
        let quiet = try bytes(0), speech = try bytes(0.8)
        let centerBand = (65..<107).flatMap { row in (65..<235).map { (row * 300 + $0) * 4 } }
        let quietLight = centerBand.reduce(0) { $0 + Int(quiet[$1]) + Int(quiet[$1+1]) + Int(quiet[$1+2]) }
        let speechLight = centerBand.reduce(0) { $0 + Int(speech[$1]) + Int(speech[$1+1]) + Int(speech[$1+2]) }
        XCTAssertGreaterThan(speechLight, quietLight * 2, "说话时光波必须显著增强")
        XCTAssertTrue(centerBand.contains { Int(quiet[$0 + 2]) > Int(quiet[$0]) + 8 }, "静音时仍须保留暖色光波")
        XCTAssertTrue(centerBand.contains { Int(quiet[$0]) > Int(quiet[$0 + 2]) + 8 }, "静音时仍须保留冷色光波，不能统一变为暖白")
        for i in [0, 299, 199*300, 200*300-1] { XCTAssertEqual(speech[i*4+3], 0, "玻璃外必须透明") }
        renderer.elapsed = 3.5
        let next = try bytes(0.8)
        XCTAssertNotEqual(speech, next, "相位变化必须产生真实动态帧")
    }
    func testWaveLightCouplesLocallyToGlassAndFollowsPhase() throws {
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("Metal unavailable on this runner") }
        let renderer = try SiriMetalRenderer()
        renderer.progress = 1; renderer.intro = 2; renderer.energy = 0.8
        func interaction(_ time: Float) throws -> [Int] {
            renderer.elapsed = time
            renderer.lightGlassCoupling = 0
            let original = try renderer.snapshot(size: CGSize(width: 300, height: 200), scale: 1)
            renderer.lightGlassCoupling = 1
            let coupled = try renderer.snapshot(size: CGSize(width: 300, height: 200), scale: 1)
            let before = Array(original.dataProvider!.data! as Data)
            let after = Array(coupled.dataProvider!.data! as Data)
            var difference = [Int](repeating: 0, count: 300 * 200)
            for pixel in 0..<difference.count {
                let offset = pixel * 4
                XCTAssertEqual(after[offset + 3], before[offset + 3], "反光不得改变玻璃轮廓或外部透明度")
                difference[pixel] = (0..<3).reduce(0) { $0 + Int(after[offset + $1]) - Int(before[offset + $1]) }
            }
            return difference
        }
        let first = try interaction(2.5), next = try interaction(3.5)
        var sides = [Int]()
        for row in 45..<125 {
            for column in 55..<80 { sides.append(row * 300 + column) }
            for column in 220..<245 { sides.append(row * 300 + column) }
        }
        let center = (65..<100).flatMap { row in (110..<190).map { row * 300 + $0 } }
        XCTAssertGreaterThan(sides.reduce(0) { $0 + first[$1] }, 100, "真实光线必须在两侧曲面产生可见反射")
        // The approved material includes weak volume scattering inside the body.
        // Bound its contribution rather than requiring the entire center to be unlit.
        let centerMean = Double(center.reduce(0) { $0 + abs(first[$1]) }) / Double(center.count * 3)
        // Less than roughly 3% of the 8-bit range allows the approved gentle
        // scattering without turning the center into a white veil.
        XCTAssertLessThanOrEqual(centerMean, 8, "内部散射应克制，不应整体洗白玻璃中心")
        XCTAssertNotEqual(first, next, "反射须随光波相位改变，不能是固定贴图")
    }
    func testSiriStylePersistsAndClassicGlassRemainsSelectable() {
        let suite = "SiriStyle.\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        XCTAssertEqual(OverlayAppearance.load(from: defaults).visualStyle, 1)
        OverlayAppearance(visualStyle: 0, glassAmount: 0.3, refraction: true).save(to: defaults)
        let restored = OverlayAppearance.load(from: defaults)
        XCTAssertEqual(restored.visualStyle, 0)
        XCTAssertTrue(restored.refraction)
        XCTAssertEqual(restored.glassAmount, 0.3)
    }
}
