import AppKit
import QuartzCore

final class AppearanceSettingsWindow: NSPanel {
    var onChange: ((OverlayAppearance) -> Void)?
    var onDesktopPreview: ((Bool) -> Bool)?
    var onPreviewFrame: ((Float, Bool) -> Void)?
    private let capsule = RecordingCapsuleView(frame: NSRect(x: 50, y: 19, width: 354, height: 136), inset: 40)
    private let visualStyle = NSSegmentedControl(labels: ["Siri 光波", "厚玻璃胶囊"], trackingMode: .selectOne, target: nil, action: nil)
    private let modes = NSSegmentedControl(labels: ["自动", "安静", "轻声", "说话", "强调"],
                                           trackingMode: .selectOne, target: nil, action: nil)
    private let state = NSTextField(labelWithString: "自动演示：安静 → 轻声 → 说话 → 识别")
    private let meter = NSLevelIndicator()
    private let gain = NSSlider()
    private let glassSlider = NSSlider()
    private let material = NSSegmentedControl(labels: ["通透", "柔和"], trackingMode: .selectOne, target: nil, action: nil)
    private let glassValue = NSTextField(labelWithString: "")
    private let desktopPreview = NSButton(checkboxWithTitle: "桌面预览", target: nil, action: nil)
    private let refractionToggle = NSButton(checkboxWithTitle: "背景折射", target: nil, action: nil)
    private let refractionNote = NSTextField(labelWithString: "")
    private let refractionStrength = NSSlider()
    private var settings = OverlayAppearance.load()
    private var timer: Timer?
    private var lastTime: CFTimeInterval = 0
    private var elapsed: Double = 0
    private var listening = false

    init() {
        super.init(contentRect: NSRect(x: 0, y: 0, width: 510, height: 600),
                   styleMask: [.titled, .closable], backing: .buffered, defer: false)
        title = "VoiceInput · 外观设置"
        isReleasedWhenClosed = false
        buildUI()
        center()
    }

    func showSettings() {
        settings = .load()
        visualStyle.selectedSegment = settings.visualStyle == 1 ? 0 : 1
        gain.doubleValue = settings.motionGain
        glassSlider.doubleValue = settings.glassAmount
        material.selectedSegment = settings.material
        refractionToggle.state = settings.refraction ? .on : .off
        refractionStrength.doubleValue = settings.refractionStrength
        capsule.applyAppearance(settings)
        refreshValue()
        makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        guard timer == nil else { return }
        elapsed = 0
        lastTime = CACurrentMediaTime()
        let clock = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] _ in self?.tick() }
        clock.tolerance = 0.002
        RunLoop.main.add(clock, forMode: .common)
        timer = clock
    }

    override func close() {
        stopDesktopPreview()
        timer?.invalidate(); timer = nil
        capsule.stopAnimation(); listening = false
        super.close()
    }

    deinit { timer?.invalidate() }

    func stopDesktopPreview() {
        guard desktopPreview.state == .on else { return }
        desktopPreview.state = .off
        _ = onDesktopPreview?(false)
    }

    @objc private func toggleDesktopPreview(_ sender: NSButton) {
        let requested = sender.state == .on
        let accepted = onDesktopPreview?(requested) ?? false
        sender.state = requested && accepted ? .on : .off
        if !requested { makeKeyAndOrderFront(nil) }
    }

    private func buildUI() {
        guard let root = contentView else { return }
        let heading = NSTextField(labelWithString: "玻璃与光波，随声音起伏")
        heading.font = .systemFont(ofSize: 21, weight: .semibold)
        heading.frame = NSRect(x: 28, y: 461, width: 454, height: 30)
        root.addSubview(heading)
        let note = NSTextField(labelWithString: "实时预览 · 自动保存 · 随声音呼吸")
        note.font = .systemFont(ofSize: 12)
        note.textColor = .secondaryLabelColor
        note.frame = NSRect(x: 28, y: 430, width: 338, height: 22)
        root.addSubview(note)
        desktopPreview.target = self
        desktopPreview.action = #selector(toggleDesktopPreview(_:))
        desktopPreview.toolTip = "预览桌面玻璃折射，不会录音。此演示会临时让胶囊接收键盘焦点；按 Esc 或取消勾选后返回设置。"
        desktopPreview.frame = NSRect(x: 379, y: 430, width: 103, height: 22)
        root.addSubview(desktopPreview)
        let stage = NSView(frame: NSRect(x: 28, y: 236, width: 454, height: 174))
        stage.wantsLayer = true
        stage.layer?.cornerRadius = 18
        stage.layer?.masksToBounds = true
        if let screen = NSScreen.main,
           let url = NSWorkspace.shared.desktopImageURL(for: screen),
           let image = NSImage(contentsOf: url) {
            let wallpaper = CapsuleWallpaperView(frame: stage.bounds, image: image)
            stage.addSubview(wallpaper)
            if let background = wallpaper.renderBackground(scale: 2) {
                capsule.setRefractionBackground(background,
                    rect: CGRect(x: -capsule.frame.minX, y: -capsule.frame.minY,
                                 width: stage.bounds.width, height: stage.bounds.height))
            }
        } else {
            let effect = NSVisualEffectView(frame: stage.bounds)
            effect.material = .underWindowBackground
            effect.blendingMode = .behindWindow
            effect.state = .active
            stage.addSubview(effect)
        }
        stage.addSubview(capsule)
        root.addSubview(stage)
        modes.target = self
        modes.action = #selector(changeMode(_:))
        modes.selectedSegment = 0
        modes.frame = NSRect(x: 28, y: 181, width: 454, height: 27)
        root.addSubview(modes)
        state.font = .systemFont(ofSize: 12)
        state.textColor = .secondaryLabelColor
        state.frame = NSRect(x: 28, y: 149, width: 454, height: 20)
        root.addSubview(state)
        meter.levelIndicatorStyle = .continuousCapacity
        meter.minValue = 0; meter.maxValue = 1
        meter.warningValue = 1.1; meter.criticalValue = 1.2
        meter.frame = NSRect(x: 28, y: 125, width: 454, height: 10)
        root.addSubview(meter)
        let gainLabel = NSTextField(labelWithString: "联动幅度")
        gainLabel.font = .systemFont(ofSize: 12)
        gainLabel.frame = NSRect(x: 28, y: 91, width: 72, height: 20)
        root.addSubview(gainLabel)
        gain.minValue = 0; gain.maxValue = 2
        gain.isContinuous = true
        gain.target = self; gain.action = #selector(changeAppearance(_:))
        gain.setAccessibilityLabel("联动幅度")
        gain.frame = NSRect(x: 107, y: 89, width: 229, height: 24)
        root.addSubview(gain)
        material.target = self; material.action = #selector(changeAppearance(_:))
        material.frame = NSRect(x: 352, y: 89, width: 130, height: 24)
        root.addSubview(material)
        let separator = NSBox(frame: NSRect(x: 28, y: 76, width: 454, height: 1))
        separator.boxType = .separator
        root.addSubview(separator)
        let glassLabel = NSTextField(labelWithString: "Liquid Glass")
        glassLabel.font = .systemFont(ofSize: 12, weight: .medium)
        glassLabel.frame = NSRect(x: 28, y: 41, width: 104, height: 20)
        root.addSubview(glassLabel)
        glassSlider.minValue = 0; glassSlider.maxValue = 1
        glassSlider.isContinuous = true
        glassSlider.trackFillColor = .controlAccentColor
        glassSlider.target = self; glassSlider.action = #selector(changeAppearance(_:))
        glassSlider.setAccessibilityLabel("Liquid Glass 玻璃浓度")
        glassSlider.toolTip = "向左更通透，向右更浓厚；只调节胶囊的玻璃层。"
        glassSlider.frame = NSRect(x: 158, y: 39, width: 293, height: 24)
        root.addSubview(glassSlider)
        for (symbol, x, description) in [("rectangle.on.rectangle", 132.0, "通透"),
                                          ("rectangle.on.rectangle.fill", 460.0, "浓厚")] {
            let icon = NSImageView(frame: NSRect(x: x, y: 41, width: 22, height: 20))
            icon.image = NSImage(systemSymbolName: symbol, accessibilityDescription: description)
            icon.contentTintColor = .secondaryLabelColor
            icon.toolTip = description
            root.addSubview(icon)
        }
        glassValue.font = .systemFont(ofSize: 11)
        glassValue.textColor = .secondaryLabelColor
        glassValue.frame = NSRect(x: 28, y: 16, width: 454, height: 17)
        root.addSubview(glassValue)
        // Leave the established controls intact and add an explicit opt-in.
        root.subviews.forEach { $0.frame.origin.y += 110 }
        setContentSize(NSSize(width: 510, height: 630))
        visualStyle.frame = NSRect(x: 285, y: 92, width: 197, height: 25)
        visualStyle.target = self; visualStyle.action = #selector(changeAppearance(_:))
        visualStyle.setAccessibilityLabel("录音动效风格")
        root.addSubview(visualStyle)
        refractionToggle.frame = NSRect(x: 28, y: 64, width: 120, height: 22)
        refractionToggle.target = self
        refractionToggle.action = #selector(toggleRefraction(_:))
        refractionToggle.toolTip = "读取胶囊背后的画面来模拟曲面折射；仅在胶囊显示时处理，不保存、不上传。"
        root.addSubview(refractionToggle)
        refractionNote.font = .systemFont(ofSize: 10)
        refractionNote.textColor = .secondaryLabelColor
        refractionNote.frame = NSRect(x: 28, y: 44, width: 454, height: 16)
        root.addSubview(refractionNote)
        let strengthLabel = NSTextField(labelWithString: "折射强度")
        strengthLabel.font = .systemFont(ofSize: 12)
        strengthLabel.frame = NSRect(x: 28, y: 15, width: 75, height: 20)
        root.addSubview(strengthLabel)
        refractionStrength.minValue = 0; refractionStrength.maxValue = 32
        refractionStrength.isContinuous = true
        refractionStrength.target = self
        refractionStrength.action = #selector(changeAppearance(_:))
        refractionStrength.setAccessibilityLabel("背景折射强度")
        refractionStrength.toolTip = "向右增加背景文字的弯曲和压缩，前景文字不会变形。"
        refractionStrength.frame = NSRect(x: 107, y: 13, width: 338, height: 24)
        root.addSubview(refractionStrength)
        let strong = NSTextField(labelWithString: "强")
        strong.font = .systemFont(ofSize: 11); strong.textColor = .secondaryLabelColor
        strong.frame = NSRect(x: 459, y: 16, width: 23, height: 18)
        root.addSubview(strong)
    }

    @objc private func toggleRefraction(_ sender: NSButton) {
        if sender.state == .on, !CGPreflightScreenCaptureAccess() {
            _ = CGRequestScreenCaptureAccess()
        }
        changeAppearance(sender)
    }

    @objc private func changeAppearance(_ sender: NSControl) {
        settings = OverlayAppearance(visualStyle: visualStyle.selectedSegment == 0 ? 1 : 0, glassAmount: glassSlider.doubleValue,
                                     motionGain: gain.doubleValue, material: material.selectedSegment,
                                     refraction: refractionToggle.state == .on,
                                     refractionStrength: refractionStrength.doubleValue)
        settings.save()
        capsule.applyAppearance(settings)
        onChange?(settings)
        refreshValue()
    }

    private func refreshValue() {
        refractionNote.stringValue = settings.refraction
            ? (CGPreflightScreenCaptureAccess() ? "已开启 · 画面仅在本机内存中处理，不保存、不上传"
                : "窗口内可预览；桌面折射需在系统设置允许屏幕录制，再重新打开软件")
            : "开启后可让胶囊边缘的背景产生弯曲 · 需要屏幕录制权限"
        glassValue.stringValue = NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency
            ? "已跟随系统的「降低透明度」设置"
            : "通透 ↔ 浓厚 · 玻璃浓度 \(Int((settings.glassAmount * 100).rounded()))%"
    }

    @objc private func changeMode(_ sender: NSSegmentedControl) {
        elapsed = 0
        state.stringValue = sender.selectedSegment == 0 ? "自动演示：安静 → 轻声 → 说话 → 识别" : "模拟音量 · 无需录音"
    }

    private func tick() {
        let now = CACurrentMediaTime()
        elapsed += min(0.05, max(0, now - lastTime))
        lastTime = now
        let cycle = elapsed.truncatingRemainder(dividingBy: 12)
        var strength = 0.0
        var recording = true
        switch modes.selectedSegment {
        case 1: strength = 0
        case 2: strength = 0.3
        case 3: strength = 0.72
        case 4: strength = 1
        default:
            if cycle < 1.5 { strength = 0 }
            else if cycle < 4 { strength = 0.3 }
            else if cycle < 8.5 { strength = 0.78 }
            else if cycle < 10 { recording = false }
        }
        if recording != listening {
            listening = recording
            if recording { capsule.startRecording() } else { capsule.stopRecording() }
        }
        capsule.text = recording ? "正在聆听…" : "正在识别…"
        let syllable = max(0, sin(elapsed * 8.7) * 0.62 + sin(elapsed * 15.2 + 1) * 0.25 + 0.32)
        let phrase = sin(elapsed * 1.8) < -0.82 ? 0.10 : 1
        let level = min(1, strength * (0.23 + syllable * 0.82) * phrase)
        meter.doubleValue = level
        capsule.setAudioLevel(Float(level))
        if desktopPreview.state == .on { onPreviewFrame?(Float(level), recording) }
    }
}

private final class CapsuleWallpaperView: NSView {
    private let image: NSImage
    init(frame: NSRect, image: NSImage) { self.image = image; super.init(frame: frame) }
    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }
    func renderBackground(scale: CGFloat) -> CGImage? {
        guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil,
            pixelsWide: Int(bounds.width * scale), pixelsHigh: Int(bounds.height * scale),
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
            let context = NSGraphicsContext(bitmapImageRep: bitmap) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        context.cgContext.scaleBy(x: scale, y: scale)
        draw(bounds)
        NSGraphicsContext.restoreGraphicsState()
        return bitmap.cgImage
    }
    override func draw(_ dirtyRect: NSRect) {
        let aspect = bounds.width / bounds.height
        let size = image.size
        var crop = NSRect(origin: .zero, size: size)
        if size.width / size.height > aspect {
            crop.size.width = size.height * aspect
            crop.origin.x = (size.width - crop.width) / 2
        } else {
            crop.size.height = size.width / aspect
            crop.origin.y = (size.height - crop.height) / 2
        }
        image.draw(in: bounds, from: crop, operation: .copy, fraction: 1)
    }
}
