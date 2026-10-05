import AppKit
import MetalKit
import QuartzCore
final class SiriGlassView: MTKView, MTKViewDelegate {
    private let renderer: SiriMetalRenderer
    private var motion = SiriMotion()
    private(set) var renderedFrameCount = 0
    var usesPixelBufferBackground: Bool { renderer.usesPixelBufferBackground }
    private var previous: CFTimeInterval = 0
    var simulatedAudio = false
    private var audioGain: Float = 1
    private var dismissalCompletion: (() -> Void)?
    init(renderingFrame frame: CGRect) throws {
        renderer = try SiriMetalRenderer()
        super.init(frame: frame, device: renderer.device)
        colorPixelFormat = .bgra8Unorm
        clearColor = MTLClearColorMake(0, 0, 0, 0)
        wantsLayer = true
        layer?.isOpaque = false
        preferredFramesPerSecond = 60
        isPaused = true
        enableSetNeedsDisplay = false
        delegate = self
        setAccessibilityLabel("Siri 风格录音动效")
    }
    required init(coder: NSCoder) { fatalError() }
    func setBackground(_ image: CGImage?, rect: CGRect? = nil) { renderer.setBackground(image, rect: rect) }
    func setBackground(_ frame: CapsuleBackdropFrame, rect: CGRect) { renderer.setBackground(frame, rect: rect) }
    func begin() { dismissalCompletion = nil; motion.begin(); previous = CACurrentMediaTime(); isPaused = false; draw() }
    func end(completion: (() -> Void)? = nil) {
        if let completion { dismissalCompletion = completion }
        motion.end()
        if motion.hasSettled { finishDismissal() }
    }
    func stop() { dismissalCompletion = nil; isPaused = true; motion = SiriMotion() }
    private func finishDismissal() {
        isPaused = true
        let callback = dismissalCompletion; dismissalCompletion = nil
        callback?()
    }
    func setLevel(_ level: Float) { motion.setLevel(level * audioGain) }
    func apply(glass: Double, refraction: Double, gain: Double = 1) { audioGain = Float(gain); renderer.glassAmount = Float(glass); renderer.refractionStrength = Float(refraction) }
    override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); if window == nil { stop() } }
    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}
    func draw(in view: MTKView) {
        renderedFrameCount += 1
        let now = CACurrentMediaTime()
        let reduced = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        motion.step(now - previous, reducedMotion: reduced); previous = now
        if simulatedAudio { setLevel(Float(max(0.04, 0.50 + sin(motion.elapsed * 4.3) * 0.35 + sin(motion.elapsed * 11) * 0.14))) }
        renderer.progress = Float(motion.progress)
        renderer.intro = Float(motion.intro)
        renderer.energy = Float(motion.energy)
        renderer.exitLightScale = Float(motion.exitLightScale)
        renderer.lightOpacity = Float(motion.lightOpacity)
        renderer.opacity = Float(motion.opacity)
        renderer.elapsed = reduced ? 0.8 : Float(motion.elapsed)
        renderer.reducedTransparency = NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency
        renderer.draw(in: view)
        if motion.hasSettled { finishDismissal() }
    }
}
