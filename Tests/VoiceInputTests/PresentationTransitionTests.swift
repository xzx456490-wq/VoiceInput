import XCTest
import Metal
@testable import VoiceInput

final class PresentationTransitionTests: XCTestCase {
    func testOpeningKeepsMovingThroughSizeToShapeHandoff() {
        var motion = SiriMotion(); motion.begin()
        motion.step(1.0/60)
        XCTAssertGreaterThan(motion.presentationScale, 0)
        XCTAssertLessThan(motion.presentationScale, 0.02)
        XCTAssertEqual(motion.progress, 0)
        XCTAssertEqual(motion.lightOpacity, 0)
        var height = 0.0
        var sawOverlap = false
        for _ in 1..<29 {
            motion.step(1.0/60)
            // The effective contour cannot stop midway when size hands off to shape.
            let nextHeight = motion.presentationScale * (11.5 + 29.5 * motion.progress)
            XCTAssertGreaterThan(nextHeight, height)
            if motion.progress > 0 && motion.presentationScale < 1 { sawOverlap = true }
            height = nextHeight
        }
        XCTAssertTrue(sawOverlap)
        XCTAssertEqual(motion.presentationScale, 1)
        XCTAssertEqual(motion.progress, 1, accuracy: 1e-9)
        XCTAssertEqual(motion.lightOpacity, 1)
    }
    func testClosingKeepsMovingThroughShapeToSizeHandoff() {
        var motion = SiriMotion(); motion.begin(); motion.step(1)
        motion.end()
        var height = 41.0
        var sawOverlap = false
        for _ in 0..<33 {
            motion.step(1.0/60)
            let nextHeight = motion.presentationScale * (11.5 + 29.5 * motion.progress)
            XCTAssertLessThan(nextHeight, height)
            if motion.progress > 0 && motion.presentationScale < 1 { sawOverlap = true }
            height = nextHeight
        }
        XCTAssertTrue(sawOverlap)
        XCTAssertTrue(motion.hasSettled)
        XCTAssertEqual(motion.presentationScale, 0)
        XCTAssertEqual(motion.opacity, 0)
    }
    func testLateFrameUsesRealTimeInsteadOfStretchingAnimation() {
        var motion = SiriMotion(); motion.begin()
        motion.step(0.48)
        XCTAssertEqual(motion.progress, 1)
        XCTAssertEqual(motion.presentationScale, 1)
        motion.end(); motion.step(0.54)
        XCTAssertTrue(motion.hasSettled)
        XCTAssertEqual(motion.presentationScale, 0)
    }
    func testReleaseDuringExpansionKeepsCurrentContourAndOnlyShrinks() {
        var motion = SiriMotion(); motion.begin(); motion.step(0.23)
        let startScale = motion.presentationScale, startProgress = motion.progress
        XCTAssertGreaterThan(startProgress, 0)
        XCTAssertLessThan(startProgress, 1)
        motion.end()
        XCTAssertEqual(motion.presentationScale, startScale)
        XCTAssertEqual(motion.progress, startProgress)
        var scale = startScale, progress = startProgress
        for _ in 0..<34 {
            motion.step(1.0/60)
            XCTAssertLessThanOrEqual(motion.presentationScale, scale)
            XCTAssertLessThanOrEqual(motion.progress, progress)
            scale = motion.presentationScale; progress = motion.progress
        }
        XCTAssertTrue(motion.hasSettled)
    }
    func testQuickReleaseNeverGrowsOrFlashesFullSize() {
        var motion = SiriMotion(); motion.begin()
        for _ in 0..<6 { motion.step(1.0/60) }
        let initialScale = motion.presentationScale
        motion.end(); motion.setLevel(1)
        for _ in 0..<31 {
            motion.step(1.0/60)
            XCTAssertLessThanOrEqual(motion.presentationScale, initialScale)
            XCTAssertEqual(motion.progress, 0)
            XCTAssertEqual(motion.lightOpacity, 0)
        }
        XCTAssertTrue(motion.hasSettled)
        motion.begin(); motion.step(1.0/60, reducedMotion: true)
        XCTAssertEqual(motion.presentationScale, 1)
        XCTAssertEqual(motion.progress, 1)
        motion.end(); motion.step(1.0/60, reducedMotion: true)
        XCTAssertEqual(motion.presentationScale, 0)
        XCTAssertTrue(motion.hasSettled)
    }
    func testRealShaderScalesPillAndLeavesNoFinalPixels() throws {
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("Metal unavailable") }
        let renderer = try SiriMetalRenderer()
        renderer.progress = 0; renderer.lightOpacity = 0
        func pixels(_ scale: Float) throws -> Int {
            renderer.presentationScale = scale
            let image = try renderer.snapshot(size: CGSize(width: 260,height: 180), scale: 1)
            let bytes = Array(image.dataProvider!.data! as Data)
            return stride(from: 3,to: bytes.count,by: 4).filter { bytes[$0] > 127 }.count
        }
        XCTAssertEqual(try pixels(0), 0)
        let small = try pixels(0.25), full = try pixels(1)
        XCTAssertGreaterThan(small, 0)
        XCTAssertLessThan(small, full/8)
        XCTAssertGreaterThan(full, 1000)
        XCTAssertEqual(try pixels(0), 0)
    }
    func testReleaseGateStopsPendingStartupOnBusyAudioQueue() {
        let gate = AudioStartupGate()
        let queue = DispatchQueue(label: "test.delayed-audio")
        let ready = DispatchSemaphore(value: 0)
        let finished = expectation(description: "pending startup is skipped")
        queue.async {
            ready.wait()
            XCTAssertFalse(gate.permitsAudio)
            finished.fulfill()
        }
        gate.stop(); ready.signal()
        wait(for: [finished], timeout: 1)
        // A new press has a different gate and cannot revive the released one.
        XCTAssertTrue(AudioStartupGate().permitsAudio)
        XCTAssertFalse(gate.permitsAudio)
    }
}
