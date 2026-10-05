import AppKit
import QuartzCore

final class OverlayPanel: NSPanel {
    private let capsule = RecordingCapsuleView()
    private let padding: CGFloat = 32
    private var panelHeight: CGFloat { appearanceSettings.visualStyle == 1 ? 180 : 120 }
    private var animationID = UUID()
    private let backdropCapture = CapsuleBackdropCapture()
    private var appearanceSettings = OverlayAppearance.load()

    var onPreviewEscape: (() -> Void)?
    private var nativeGlassPreview = false
    private var holdsKeyboardFocus = false
    private var endingPresentation = false
    private var presentationCompletions: [() -> Void] = []
    override var canBecomeKey: Bool { holdsKeyboardFocus }
    override var canBecomeMain: Bool { false }

    init() {
        super.init(contentRect: NSRect(x: 0, y: 0, width: 338, height: 120),
                   styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isFloatingPanel = true
        level = .floating
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        isMovableByWindowBackground = false
        hidesOnDeactivate = false
        ignoresMouseEvents = true
        capsule.frame = contentView!.bounds
        capsule.autoresizingMask = [.width, .height]
        contentView!.addSubview(capsule)
        backdropCapture.onFrame = { [weak self] image, rect in
            guard let self, self.isVisible else { return }
            self.capsule.setRefractionBackground(image, rect: self.convertFromScreen(rect))
        }
        backdropCapture.onStop = { [weak self] in self?.capsule.setRefractionBackground(nil) }
    }

    func applyAppearance(_ settings: OverlayAppearance) {
        appearanceSettings = settings
        capsule.applyAppearance(settings)
        updateBackdropCapture()
    }

    private func updateBackdropCapture() {
        guard isVisible, appearanceSettings.refraction,
              !NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency,
              let screen = screen ?? NSScreen.main else { backdropCapture.stop(); return }
        // Covers every supported capsule width and its short entrance motion.
        let area = screen.visibleFrame
        let width = min(area.width, 800)
        let region = CGRect(x: area.midX - width / 2, y: area.minY + 4, width: width, height: 250)
        backdropCapture.start(screen: screen, region: region)
    }

    func stopBackdropCapture() { backdropCapture.stop() }

    func show(text: String = "正在聆听…", nativeGlassPreview: Bool = false) {
        if endingPresentation { finishPresentationNow() }
        let enteringFocus = !holdsKeyboardFocus
        holdsKeyboardFocus = true
        self.nativeGlassPreview = nativeGlassPreview
        title = nativeGlassPreview ? "VoiceInput · 桌面玻璃预览" : "VoiceInput · 录音"
        animationID = UUID()
        capsule.stopAnimation()
        capsule.text = text
        appearanceSettings = .load()
        capsule.applyAppearance(appearanceSettings)
        guard let screen = NSScreen.main else { return }
        let width = idealWidth(for: text, screen: screen)
        let area = screen.visibleFrame
        let destination = NSRect(x: area.midX - width / 2, y: area.minY + 56 - padding,
                                 width: width, height: panelHeight)
        let reduced = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        setFrame(destination.offsetBy(dx: 0, dy: reduced ? 0 : -14), display: true)
        alphaValue = 0
        orderFrontRegardless()
        // Preserve the established focus/exit lifecycle while the panel stays
        // nonactivating and the original application remains frontmost.
        if enteringFocus { makeKey() }
        updateBackdropCapture()
        capsule.startRecording()
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = reduced ? 0 : 0.35
            ctx.timingFunction = CAMediaTimingFunction(controlPoints: 0.175, 0.885, 0.32, 1)
            animator().alphaValue = 1
            animator().setFrame(destination, display: true)
        }
    }

    override func keyDown(with event: NSEvent) {
        if nativeGlassPreview && event.keyCode == 53 {
            onPreviewEscape?()
            return
        }
        super.keyDown(with: event)
    }

    func updateText(_ text: String) {
        capsule.text = text
        guard let screen = screen ?? NSScreen.main else { return }
        let width = idealWidth(for: text, screen: screen)
        guard abs(width - frame.width) > 0.5 else { return }
        let destination = NSRect(x: screen.visibleFrame.midX - width / 2, y: frame.minY,
                                 width: width, height: panelHeight)
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0 : 0.25
            ctx.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            animator().setFrame(destination, display: true)
        }
    }

    func updateAudioLevel(_ level: Float) { capsule.setAudioLevel(level) }
    func showRefining() { showProcessing("正在纠错…") }
    func showProcessing(_ text: String) {
        capsule.stopRecording()
        updateText(text)
        if !nativeGlassPreview { endRecordingPresentation() }
    }

    // End the visible glass while it is still key. AppKit must not switch
    // its optical treatment before the exit animation has finished.
    func endRecordingPresentation(completion: (() -> Void)? = nil) {
        if let completion { presentationCompletions.append(completion) }
        guard !endingPresentation else { return }
        guard isVisible, holdsKeyboardFocus else {
            finishPresentationNow()
            return
        }
        endingPresentation = true
        let id = animationID
        if capsule.usesSiriPresentation {
            // Hide only after the shared renderer has faded its last frame.
            // The generation guard prevents a late exit from hiding a new session.
            let finish = { [weak self] in
                guard let self, self.animationID == id, self.endingPresentation else { return }
                self.finishPresentationNow()
            }
            capsule.stopRecording(completion: finish)
            // A hidden/occluded Metal view may stop receiving display ticks.
            DispatchQueue.main.asyncAfter(deadline: .now() + 2, execute: finish)
            return
        }
        capsule.stopRecording()
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0 : (self.appearanceSettings.visualStyle == 1 ? 0.42 : 0.16)
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            guard let self, self.animationID == id else { return }
            self.finishPresentationNow()
        })
    }

    private func finishPresentationNow() {
        // Ordering out returns the nonactivating panel's keyboard focus.
        // Keep it hidden rather than re-showing the now-inactive material.
        orderOut(nil)
        backdropCapture.stop()
        holdsKeyboardFocus = false
        endingPresentation = false
        capsule.stopAnimation()
        let callbacks = presentationCompletions
        presentationCompletions.removeAll()
        callbacks.forEach { $0() }
    }

    func dismiss() {
        if nativeGlassPreview {
            finishPresentationNow()
            nativeGlassPreview = false
        } else { endRecordingPresentation() }
    }

    private func idealWidth(for text: String, screen: NSScreen) -> CGFloat {
        if appearanceSettings.visualStyle == 1 { return min(260, screen.visibleFrame.width - 24) }
        let font = NSFont.systemFont(ofSize: 15, weight: .medium)
        let textWidth = ceil((text as NSString).size(withAttributes: [.font: font]).width)
        let capsuleWidth = 114 + min(max(textWidth, 160), 560)
        // Room for the shell expansion and shadow, including on small displays.
        return min(capsuleWidth + padding * 2, screen.visibleFrame.width - 24)
    }
}
