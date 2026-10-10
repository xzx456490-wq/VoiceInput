import AppKit
import Speech

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem!
    private let keyMonitor = KeyMonitor()
    private let speechEngine = SpeechEngine()
    private let loginAtLaunch = LoginAtLaunch()
    private let injector = TextInjector()
    private lazy var overlay = OverlayPanel()
    private lazy var settings = SettingsWindow()
    private lazy var appearanceSettings: AppearanceSettingsWindow = {
        let window = AppearanceSettingsWindow()
        overlay.onPreviewEscape = { [weak window] in
            window?.stopDesktopPreview()
            window?.showSettings()
        }
        window.onChange = { [weak self] appearance in self?.overlay.applyAppearance(appearance) }
        window.onDesktopPreview = { [weak self] enabled in
            guard let self else { return false }
            if enabled {
                guard self.session.phase == .idle else { return false }
                self.previewingOnDesktop = true
                self.previewRecording = true
                self.overlay.show(text: "预览 · 正在聆听…", nativeGlassPreview: true)
                return true
            }
            if self.previewingOnDesktop {
                self.previewingOnDesktop = false
                self.overlay.dismiss()
            }
            return false
        }
        window.onPreviewFrame = { [weak self] level, recording in
            guard let self, self.previewingOnDesktop, self.session.phase == .idle else { return }
            if recording != self.previewRecording {
                self.previewRecording = recording
                if recording { self.overlay.show(text: "预览 · 正在聆听…", nativeGlassPreview: true) }
                else { self.overlay.showProcessing("预览 · 正在识别…") }
            }
            self.overlay.updateAudioLevel(level)
        }
        return window
    }()
    private var previewingOnDesktop = false
    private var previewRecording = false
    private var session = RecordingSession()
    private var target: TextInjector.Target?
    private var finalTimer: Timer?
    private var refinementTask: URLSessionDataTask?
    private var isEnabled = false
    private var lastText = ""
    private var statusMessage = "尚未开启，先检查权限"
    private var enableItem: NSMenuItem!
    private var llmItem: NSMenuItem!
    private var statusMenuItem: NSMenuItem!
    private var copyItem: NSMenuItem!
    private var loginItem: NSMenuItem!
    private var languageItems: [NSMenuItem] = []
    private var selectedLocale: String {
        get { UserDefaults.standard.string(forKey: "selectedLocaleCode") ?? "zh-CN" }
        set { UserDefaults.standard.set(newValue, forKey: "selectedLocaleCode") }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        OverlayAppearance.applyThickGlassPresetIfNeeded()
        let supported = ["zh-CN", "zh-TW", "en-US", "ja-JP", "ko-KR"]
        if !supported.contains(selectedLocale) { selectedLocale = "zh-CN" }
        speechEngine.locale = Locale(identifier: selectedLocale)
        setupMenu()
        // Compile/prepare the native glass before installing the Fn event tap.
        _ = overlay
        loginAtLaunch.configureInitialPreference()
        keyMonitor.onFnDown = { [weak self] in self?.fnDown() }
        keyMonitor.onFnUp = { [weak self] in self?.fnUp() }
        speechEngine.onResult = { [weak self] id, text, final in
            guard let self, self.session.receive(text, final: final, id: id) else { return }
            self.overlay.updateText(text.isEmpty ? "正在聆听…" : text)
            if final && self.session.phase == .waiting { self.finish(id: id) }
        }
        speechEngine.onAudioLevel = { [weak self] id, level in
            guard let self, self.session.id == id, self.session.phase == .recording else { return }
            self.overlay.updateAudioLevel(level)
        }
        speechEngine.onError = { [weak self] id, message in
            guard let self, self.session.id == id else { return }
            if self.session.phase == .waiting && !self.session.text.isEmpty { self.finish(id: id) }
            else if self.session.phase == .recording || self.session.phase == .waiting { self.fail(message) }
        }
        if SpeechEngine.hasPermissions && AXIsProcessTrusted() {
            isEnabled = keyMonitor.start()
            statusMessage = isEnabled ? "按住 Fn 说话，松开输入" : "需要辅助功能或输入监控权限"
        }
        if !UserDefaults.standard.bool(forKey: "didShowWelcome") {
            UserDefaults.standard.set(true, forKey: "didShowWelcome")
            DispatchQueue.main.async { [weak self] in
                self?.alert("VoiceInput 已就绪", "点击屏幕顶部的麦克风图标 →「检查权限并开启」，按系统提示允许麦克风、语音识别和辅助功能。\n\n然后点进输入框，按住 Fn 说中文，松开即可输入。大模型纠错目前关闭，可以以后再配置。")
            }
        }
        let appearanceVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        if !UserDefaults.standard.bool(forKey: "didShowGlassAppearance")
            || UserDefaults.standard.string(forKey: "didShowGlassAppearanceVersion") != appearanceVersion {
            UserDefaults.standard.set(true, forKey: "didShowGlassAppearance")
            UserDefaults.standard.set(appearanceVersion, forKey: "didShowGlassAppearanceVersion")
            DispatchQueue.main.async { [weak self] in self?.appearanceSettings.showSettings() }
        }
    }
    func applicationWillTerminate(_ notification: Notification) {
        refinementTask?.cancel(); finalTimer?.invalidate(); speechEngine.cancel(); keyMonitor.stop(); overlay.stopBackdropCapture()
    }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { appearanceSettings.showSettings() }
        return true
    }
    private func fnDown() {
        guard isEnabled, SpeechEngine.hasPermissions, let id = session.begin() else { return }
        if previewingOnDesktop { appearanceSettings.stopDesktopPreview() }
        target = TextInjector.captureTarget()
        statusMessage = "正在录音"; updateIcon()
        overlay.show(text: "正在聆听…")
        speechEngine.startRecording(id: id)
    }
    private func fnUp() {
        guard session.release() else { return }
        let id = session.id
        overlay.endRecordingPresentation()
        statusMessage = "正在识别"
        updateIcon(); overlay.showProcessing("正在识别…")
        finalTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: false) { [weak self] _ in self?.finish(id: id) }
        speechEngine.stopRecording()
        if session.hasFinalResult { finish(id: id) }
    }
    private func finish(id: UUID) {
        let refiner = LLMRefiner.shared
        let shouldRefine = refiner.isEnabled && refiner.isConfigured
        guard let text = session.finish(id: id, refine: shouldRefine) else { return }
        finalTimer?.invalidate(); finalTimer = nil; speechEngine.cancel()
        guard !text.isEmpty else { reset(); overlay.dismiss(); return }
        if shouldRefine {
            statusMessage = "正在纠错"; overlay.showRefining()
            refinementTask = refiner.refine(text, configuration: refiner.configuration) { [weak self] result in
                guard let self, self.session.id == id, self.session.phase == .refining else { return }
                self.refinementTask = nil
                switch result {
                case .success(let finalText): self.paste(finalText, id: id)
                case .failure: self.statusMessage = "纠错失败，已使用原始识别文字"; self.paste(text, id: id, fallback: true)
                }
            }
        } else { paste(text, id: id) }
    }
    private func paste(_ text: String, id: UUID, fallback: Bool = false) {
        guard session.prepareInjection(id: id) else { return }
        lastText = text
        overlay.showProcessing(fallback ? "纠错失败，正在输入原文…" : text)
        let destination = target
        // Even an already-final result must wait until the panel has hidden
        // and WindowServer has returned keyboard focus to the input window.
        overlay.endRecordingPresentation { [weak self] in
            guard let self, self.session.id == id, self.session.phase == .injecting else { return }
            self.injector.inject(text, into: destination) { [weak self] success in
                guard let self, self.session.id == id else { return }
                self.reset()
                if success {
                    self.statusMessage = fallback ? "纠错失败，已使用原始识别文字" : "按住 Fn 说话，松开输入"
                    self.overlay.dismiss()
                } else {
                    self.statusMessage = "输入位置已变化；可在菜单复制上次结果"
                    self.overlay.showProcessing("未粘贴：请从菜单复制上次结果")
                    self.dismissLater()
                }
            }
        }
    }

    private func reset() {
        finalTimer?.invalidate(); finalTimer = nil
        refinementTask?.cancel(); refinementTask = nil
        speechEngine.cancel(); session.reset(); target = nil; updateIcon()
    }
    private func fail(_ message: String) {
        reset(); statusMessage = message; overlay.showProcessing(message); dismissLater()
    }
    private func dismissLater() {
        let id = session.id
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { [weak self] in
            guard let self, self.session.id == id, !self.previewingOnDesktop else { return }
            self.overlay.dismiss()
        }
    }
    private func setupMenu() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        updateIcon()
        let menu = NSMenu(); menu.delegate = self
        statusMenuItem = NSMenuItem(title: statusMessage, action: nil, keyEquivalent: ""); menu.addItem(statusMenuItem)
        enableItem = add("启用语音输入", action: #selector(toggleEnabled), to: menu)
        add("检查权限并开启…", action: #selector(checkPermissions), to: menu)
        menu.addItem(.separator())
        let language = NSMenuItem(title: "识别语言", action: nil, keyEquivalent: "")
        let languageMenu = NSMenu()
        for (name, code) in [("简体中文", "zh-CN"), ("繁體中文", "zh-TW"), ("英语", "en-US"), ("日本語", "ja-JP"), ("한국어", "ko-KR")] {
            let item = add(name, action: #selector(changeLanguage(_:)), to: languageMenu)
            item.representedObject = code; languageItems.append(item)
        }
        language.submenu = languageMenu; menu.addItem(language)
        add("外观设置…", action: #selector(openAppearanceSettings), to: menu)
        let llm = NSMenuItem(title: "大模型纠错", action: nil, keyEquivalent: "")
        let llmMenu = NSMenu(); llmMenu.delegate = self
        llmItem = add("启用纠错", action: #selector(toggleLLM), to: llmMenu)
        add("设置…", action: #selector(openSettings), to: llmMenu)
        llm.submenu = llmMenu; menu.addItem(llm)
        copyItem = add("复制上次识别结果", action: #selector(copyLast), to: menu)
        menu.addItem(.separator())
        loginItem = add("登录时自动启动", action: #selector(toggleLoginAtLaunch), to: menu)
        add("登录项设置…", action: #selector(openLoginSettings), to: menu)
        add("使用说明…", action: #selector(showHelp), to: menu)
        add("退出 VoiceInput", action: #selector(quit), to: menu)
        statusItem.menu = menu
        let mainMenu = NSMenu()
        let appItem = NSMenuItem(title: "VoiceInput", action: nil, keyEquivalent: "")
        let appMenu = NSMenu()
        add("外观设置…", action: #selector(openAppearanceSettings), to: appMenu)
        appMenu.addItem(.separator())
        let quitItem = add("退出 VoiceInput", action: #selector(quit), to: appMenu)
        quitItem.keyEquivalent = "q"
        appItem.submenu = appMenu
        mainMenu.addItem(appItem)
        NSApp.mainMenu = mainMenu
    }
    @discardableResult private func add(_ title: String, action: Selector, to menu: NSMenu) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self; menu.addItem(item); return item
    }
    func menuWillOpen(_ menu: NSMenu) {
        enableItem.state = isEnabled ? .on : .off
        llmItem.state = LLMRefiner.shared.isEnabled ? .on : .off
        statusMenuItem.title = statusMessage
        copyItem.isEnabled = !lastText.isEmpty
        loginItem.state = loginAtLaunch.isEnabled ? .on : .off
        loginItem.title = loginAtLaunch.requiresApproval ? "登录时自动启动（待系统允许）" : "登录时自动启动"
        languageItems.forEach { $0.state = ($0.representedObject as? String) == selectedLocale ? .on : .off }
    }
    private func updateIcon() {
        guard let button = statusItem?.button else { return }
        let recording = session.phase == .recording
        button.image = NSImage(systemSymbolName: recording ? "mic.fill" : "mic", accessibilityDescription: "VoiceInput 语音输入")
        button.contentTintColor = recording ? .systemGreen : nil
        button.toolTip = "VoiceInput：按住 Fn 说话"
    }
    @objc private func toggleEnabled() {
        if previewingOnDesktop { appearanceSettings.stopDesktopPreview() }
        if isEnabled { isEnabled = false; keyMonitor.stop(); reset(); overlay.dismiss(); statusMessage = "语音输入已暂停" }
        else { checkPermissions() }
    }
    @objc private func checkPermissions() {
        SpeechEngine.requestPermissions { [weak self] granted, message in
            guard let self else { return }
            guard granted else { self.alert("需要语音权限", message ?? "请检查麦克风和语音识别权限。"); return }
            guard AXIsProcessTrusted() else {
                let pane: String
                if #available(macOS 27.0, *) { pane = "设备控制和数据访问" }
                else { pane = "辅助功能" }
                self.alert("需要设备控制权限", "请在系统设置 → 隐私与安全 → \(pane)中，添加「应用程序」里的 VoiceInput 并打开开关。\n\n如果开关已经打开但仍出现此提示，请退出 VoiceInput，从权限列表移除旧项，再用「+」重新添加 /Applications/VoiceInput.app，然后重新打开软件。")
                NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
                return
            }
            self.isEnabled = self.keyMonitor.start()
            self.statusMessage = self.isEnabled ? "按住 Fn 说话，松开输入" : "全局按键监听未开启"
            if !self.isEnabled {
                self.alert("按键监听未开启", "请检查系统设置 → 隐私与安全性 → 输入监控是否允许 VoiceInput，然后退出并重新打开软件。")
            }
        }
    }
    @objc private func changeLanguage(_ sender: NSMenuItem) {
        guard session.phase == .idle, let code = sender.representedObject as? String else { return }
        selectedLocale = code; speechEngine.locale = Locale(identifier: code)
    }
    @objc private func toggleLLM() {
        let refiner = LLMRefiner.shared
        if !refiner.isEnabled && !refiner.isConfigured { openSettings(); return }
        refiner.isEnabled.toggle()
    }
    @objc private func openSettings() { settings.showSettings() }
    @objc private func openAppearanceSettings() { appearanceSettings.showSettings() }
    @objc private func copyLast() {
        guard !lastText.isEmpty else { return }
        NSPasteboard.general.clearContents(); NSPasteboard.general.setString(lastText, forType: .string)
    }
    @objc private func toggleLoginAtLaunch() {
        do {
            try loginAtLaunch.toggle()
            if loginAtLaunch.requiresApproval { openLoginSettings() }
        } catch {
            alert("自动启动设置未完成", "\(error.localizedDescription)\n\n可在系统设置 → 通用 → 登录项与扩展中检查 VoiceInput。")
        }
    }
    @objc private func openLoginSettings() { LoginAtLaunch.openSettings() }
    @objc private func showHelp() {
        alert("VoiceInput 使用方法", "点进输入框 → 按住 Fn 说话 → 松开输入。处理期间请保持原来的输入位置。\n\n默认识别简体中文，可在菜单切换语言。大模型纠错默认关闭；以后在「大模型纠错 → 设置」填写兼容 OpenAI 的地址（通常以 /v1 结尾）、密钥和模型，再开启纠错。\n\n如果 Fn 仍出现表情窗口，可在系统设置 → 键盘，把「按下 🌐 键以」设为「不执行任何操作」。")
    }
    @objc private func quit() { NSApp.terminate(nil) }
    private func alert(_ title: String, _ message: String) {
        let alert = NSAlert(); alert.messageText = title; alert.informativeText = message
        alert.addButton(withTitle: "知道了"); NSApp.activate(ignoringOtherApps: true); alert.runModal()
    }
}
