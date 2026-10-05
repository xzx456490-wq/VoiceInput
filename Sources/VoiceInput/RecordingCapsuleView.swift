import AppKit
import QuartzCore
import CoreImage

final class RecordingCapsuleView: NSView {
    private let materialView: NSView
    private let foreground = NSView()
    private var siriGlass: SiriGlassView?
    private var usesSiri: Bool { appearanceSettings.visualStyle == 1 && siriGlass != nil }
    var usesSiriPresentation: Bool { usesSiri }
    var usesPixelBufferBackdrop: Bool { usesSiri && siriGlass?.usesPixelBufferBackground == true }
    private let lightView = CapsuleLightView()
    private let label = NSTextField(labelWithString: "正在聆听…")
    private let bars = (0..<5).map { _ in CALayer() }
    private let lensLayer = CALayer()
    private let lensQueue = DispatchQueue(label: "VoiceInput.glass.lens", qos: .userInitiated)
    private var backdrop: (frame: CapsuleBackdropFrame, rect: CGRect)?
    private lazy var backdropContext = CIContext(options: [.cacheIntermediates: false])
    private var lensGeneration = UUID()
    private var renderingLens = false
    private var lastLensRender: CFTimeInterval = 0
    private var clock: Timer?
    private var lastTime: CFTimeInterval = 0
    private var motion = CapsuleMotion()
    private var appearanceSettings = OverlayAppearance.load()
    private var accessibilityObserver: NSObjectProtocol?
    private let inset: CGFloat

    var text: String {
        get { label.stringValue }
        set {
            guard label.stringValue != newValue else { return }
            label.stringValue = newValue
            render()
        }
    }

    init(frame: NSRect = .zero, inset: CGFloat = 32) {
        self.inset = inset
        let effect = NSVisualEffectView()
        effect.material = .hudWindow
        effect.blendingMode = .behindWindow
        effect.state = .active
        effect.wantsLayer = true
        effect.layer?.masksToBounds = true
        materialView = effect
        super.init(frame: frame)
        wantsLayer = true
        lensLayer.isHidden = true
        layer?.addSublayer(lensLayer)
        addSubview(materialView)
        lightView.wantsLayer = true
        lightView.layerContentsRedrawPolicy = .onSetNeedsDisplay
        addSubview(lightView, positioned: .above, relativeTo: materialView)
        foreground.wantsLayer = true
        // The glass body comes from refracted background pixels, without a
        // separate native highlight ring or drawn border. Content stays sharp.
        addSubview(foreground, positioned: .above, relativeTo: lightView)
        label.font = .systemFont(ofSize: 15, weight: .medium)
        label.lineBreakMode = .byTruncatingTail
        label.maximumNumberOfLines = 1
        foreground.addSubview(label)
        bars.forEach { foreground.layer?.addSublayer($0) }
        accessibilityObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification,
            object: nil, queue: .main) { [weak self] _ in
                guard let self else { return }
                self.applyAppearance(self.appearanceSettings)
            }
        do {
            let view = try SiriGlassView(renderingFrame: bounds)
            view.autoresizingMask = [.width, .height]
            addSubview(view, positioned: .below, relativeTo: foreground)
            siriGlass = view
        } catch { NSLog("Siri renderer unavailable; using the existing glass: %@", error.localizedDescription) }
        applyAppearance(appearanceSettings)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }
    deinit {
        clock?.invalidate()
        if let accessibilityObserver { NSWorkspace.shared.notificationCenter.removeObserver(accessibilityObserver) }
    }

    func applyAppearance(_ settings: OverlayAppearance) {
        let previousStyle = usesSiri
        appearanceSettings = settings
        siriGlass?.isHidden = !usesSiri
        siriGlass?.apply(glass: settings.glassAmount, refraction: settings.refractionStrength, gain: settings.motionGain)
        if usesSiri {
            if let backdrop { siriGlass?.setBackground(backdrop.frame, rect: backdrop.rect) }
            clock?.invalidate(); clock = nil
            if motion.recording && !previousStyle { siriGlass?.begin() }
        } else {
            siriGlass?.setBackground(nil)
            siriGlass?.stop()
            if previousStyle { materialView.isHidden = false; lensLayer.isHidden = true }
            if motion.recording { startClock() }
        }
        materialView.alphaValue = NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency
            ? 1 : 0.12 + 0.40 * settings.glassAmount
        lightView.isHidden = NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency
        if lightView.isHidden { label.shadow = nil }
        else {
            let shadow = NSShadow()
            shadow.shadowColor = NSColor.white.withAlphaComponent(0.22)
            shadow.shadowBlurRadius = 4
            shadow.shadowOffset = .zero
            label.shadow = shadow
        }
        render()
    }

    func setRefractionBackground(_ image: CGImage?, rect: CGRect = .zero) {
        if let image { setRefractionBackground(.image(image), rect: rect); return }
        else {
            backdrop = nil
            lensGeneration = UUID()
            lensLayer.contents = nil
            lensLayer.isHidden = true
            materialView.isHidden = false
        }
        siriGlass?.setBackground(image, rect: image == nil ? nil : rect)
        render()
    }

    func setRefractionBackground(_ frame: CapsuleBackdropFrame, rect: CGRect) {
        backdrop = (frame, rect)
        if usesSiri { siriGlass?.setBackground(frame, rect: rect) }
        render()
    }

    private func renderLens(capsule: CGRect) {
        guard appearanceSettings.refraction,
              !NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency,
              let backdrop else {
            lensGeneration = UUID()
            lensLayer.isHidden = true
            lensLayer.contents = nil
            materialView.isHidden = false
            return
        }
        lensLayer.frame = bounds
        let now = CACurrentMediaTime()
        guard !renderingLens, now - lastLensRender >= 1.0 / 30 else { return }
        lastLensRender = now
        renderingLens = true
        let generation = lensGeneration
        let viewBounds = bounds
        let scale = window?.backingScaleFactor ?? 2
        let strength = CGFloat(appearanceSettings.refractionStrength)
        let concentration = appearanceSettings.glassAmount
        let softened = appearanceSettings.material == 1
        let dark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let context = backdropContext
        lensQueue.async { [weak self] in
            let frame = backdrop.frame.image(using: context).flatMap { image in
                CapsuleRefraction.shared.renderGlass(background: image, backgroundRect: backdrop.rect,
                bounds: viewBounds, capsule: capsule, scale: scale, amount: strength,
                concentration: concentration, dark: dark, softened: softened)
            }
            DispatchQueue.main.async {
                guard let self else { return }
                self.renderingLens = false
                guard !self.usesSiri, self.lensGeneration == generation, self.appearanceSettings.refraction,
                      self.backdrop != nil, self.bounds == viewBounds, let frame else { return }
                CATransaction.begin(); CATransaction.setDisableActions(true)
                self.lensLayer.contents = frame
                self.lensLayer.contentsScale = scale
                self.lensLayer.isHidden = false
                self.materialView.isHidden = true
                CATransaction.commit()
            }
        }
    }

    func startRecording() { foreground.layer?.removeAllAnimations(); foreground.alphaValue = 1; motion.begin(); if usesSiri { siriGlass?.begin() } else { startClock() }; render() }
    func stopRecording(completion: (() -> Void)? = nil) {
        let wasRecording = motion.recording
        motion.end()
        if usesSiri {
            if wasRecording {
                NSAnimationContext.runAnimationGroup { ctx in
                    ctx.duration = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0 : 0.82
                    ctx.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                    foreground.animator().alphaValue = 0
                }
            }
            siriGlass?.end(completion: completion)
        }
        render()
    }
    func setAudioLevel(_ level: Float) { motion.setLevel(Double(level)); if usesSiri { siriGlass?.setLevel(level) } }
    func stopAnimation() { clock?.invalidate(); clock = nil; motion.reset(); siriGlass?.stop(); render() }

    override func layout() { super.layout(); render() }
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        render()
    }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil { stopAnimation() }
        else if motion.recording && !usesSiri { startClock() }
    }

    private func startClock() {
        guard clock == nil, window != nil else { return }
        lastTime = CACurrentMediaTime()
        let timer = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] _ in self?.tick() }
        timer.tolerance = 0.002
        RunLoop.main.add(timer, forMode: .common)
        clock = timer
    }

    private func tick() {
        let now = CACurrentMediaTime()
        motion.step(delta: now - lastTime)
        lastTime = now
        render()
        if motion.hasSettled { clock?.invalidate(); clock = nil; motion.reset(); render() }
    }

    private func render() {
        guard bounds.width > inset * 2 else { return }
        if usesSiri {
            label.isHidden = true
            materialView.isHidden = true; lensLayer.isHidden = true; lightView.isHidden = true
            siriGlass?.frame = bounds
            foreground.frame = bounds
            bars.forEach { $0.isHidden = true }
            label.alignment = .center
            label.font = .systemFont(ofSize: 11, weight: .medium)
            label.textColor = .labelColor
            label.frame = CGRect(x: 10, y: 3, width: bounds.width - 20, height: 18)
            label.setAccessibilityValue(label.stringValue)
            return
        }
        label.isHidden = false
        lightView.isHidden = NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency
        bars.forEach { $0.isHidden = false }
        label.alignment = .natural
        label.font = .systemFont(ofSize: 15, weight: .medium)
        let reduced = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        let time = CGFloat(motion.elapsed)
        let energy = CGFloat(motion.energy)
        let breath: CGFloat = motion.recording && !reduced ? 0.5 + 0.5 * sin(time * 2.4) : 0
        let gain: CGFloat = reduced ? 0 : CGFloat(appearanceSettings.motionGain)
        let baseWidth = bounds.width - inset * 2
        let width = baseWidth + (14 * CGFloat(motion.expansion) + 1.3 * breath) * gain
        let height: CGFloat = 56 + (8 * CGFloat(motion.expansion) + 1.1 * breath) * gain
        let rect = NSRect(x: (bounds.width - width) / 2, y: (bounds.height - height) / 2,
                          width: width, height: height)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        renderLens(capsule: rect)
        materialView.frame = rect
        materialView.layer?.cornerRadius = height / 2
        foreground.frame = rect
        lightView.frame = rect
        let contentLeft = (width - baseWidth) / 2
        label.frame = NSRect(x: contentLeft + 90, y: height / 2 - 10,
                             width: max(0, baseWidth - 114), height: 21)
        label.textColor = .labelColor
        var color = NSColor.labelColor.cgColor
        foreground.effectiveAppearance.performAsCurrentDrawingAppearance { color = NSColor.labelColor.cgColor }
        let lighting = !NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency
        let weights: [CGFloat] = [0.68, 0.88, 1, 0.86, 0.64]
        for (index, bar) in bars.enumerated() {
            let phase = CGFloat(index) * 0.92
            let idle: CGFloat = 4.5 + (motion.recording && !reduced
                ? 1.6 * (0.5 + 0.5 * sin(time * 2.8 - phase)) : 0)
            let ripple: CGFloat = reduced ? 0.85 : 0.66 + 0.22 * sin(time * 10.5 - phase)
                + 0.12 * sin(time * 17.3 + phase * 1.6)
            let barHeight = idle + (motion.recording ? 27.5 * energy * weights[index] * ripple : 0)
            bar.backgroundColor = color
            bar.frame = CGRect(x: contentLeft + 28 + CGFloat(index) * 8,
                               y: height / 2 - barHeight / 2, width: 4.5, height: barHeight)
            bar.cornerRadius = 2.25
            bar.opacity = Float(0.94 + energy * 0.06)
            bar.shadowColor = NSColor.white.cgColor
            bar.shadowOffset = .zero
            bar.shadowRadius = 5
            bar.shadowOpacity = lighting ? Float(0.35 * (0.28 + 0.72 * energy)) : 0
            bar.shadowPath = CGPath(roundedRect: CGRect(origin: .zero, size: bar.bounds.size),
                                    cornerWidth: 2.25, cornerHeight: 2.25, transform: nil)
        }
        lightView.update(bars: bars.map(\.frame), text: label.stringValue,
                         frame: label.frame, font: label.font!, energy: energy)
        CATransaction.commit()
    }
}
