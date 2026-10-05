import AppKit

final class SettingsWindow: NSPanel {
    private let apiBaseURLField = NSTextField()
    private let apiKeyField = NSSecureTextField()
    private let modelField = NSTextField()
    private let statusLabel = NSTextField(wrappingLabelWithString: "")
    private lazy var testButton = NSButton(title: "测试连接", target: self, action: #selector(test))
    private var testTask: URLSessionDataTask?
    private var testID = UUID()

    init() {
        super.init(contentRect: NSRect(x: 0, y: 0, width: 570, height: 300),
                   styleMask: [.titled, .closable], backing: .buffered, defer: false)
        title = "大模型纠错设置"
        isReleasedWhenClosed = false
        setupUI()
        center()
    }

    override func close() {
        testID = UUID(); testTask?.cancel(); testTask = nil
        super.close()
    }

    func showSettings() {
        testID = UUID()
        testTask?.cancel()
        testTask = nil
        testButton.isEnabled = true
        let refiner = LLMRefiner.shared
        apiBaseURLField.stringValue = refiner.apiBaseURL
        apiKeyField.stringValue = refiner.apiKey
        modelField.stringValue = refiner.model
        statusLabel.stringValue = ""
        makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func setupUI() {
        guard let cv = contentView else { return }
        apiBaseURLField.placeholderString = "https://你的服务地址/v1"
        apiKeyField.placeholderString = "API 密钥"
        modelField.placeholderString = "填写服务商提供的模型名称"
        [apiBaseURLField, apiKeyField, modelField].forEach {
            $0.isEditable = true
            $0.isSelectable = true
        }
        let labels = ["API 地址", "API 密钥", "模型名称"].map { text -> NSTextField in
            let label = NSTextField(labelWithString: text)
            label.alignment = .right
            return label
        }
        let clear = NSButton(title: "清空", target: self, action: #selector(clearKey))
        let keyRow = NSStackView(views: [apiKeyField, clear])
        keyRow.spacing = 8
        apiKeyField.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let grid = NSGridView(views: [[labels[0], apiBaseURLField], [labels[1], keyRow],
                                      [labels[2], modelField]])
        grid.translatesAutoresizingMaskIntoConstraints = false
        grid.column(at: 0).xPlacement = .trailing
        grid.rowSpacing = 14
        grid.columnSpacing = 12

        let note = NSTextField(wrappingLabelWithString:
            "支持兼容 OpenAI 的接口。启用纠错后，识别文字会发送给你填写的服务商；录音不发送给大模型。密钥保存在系统钥匙串。")
        note.font = .systemFont(ofSize: 12)
        note.textColor = .secondaryLabelColor
        note.translatesAutoresizingMaskIntoConstraints = false
        statusLabel.font = .systemFont(ofSize: 12)
        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        let saveButton = NSButton(title: "保存", target: self, action: #selector(save))
        saveButton.keyEquivalent = "\r"
        let buttons = NSStackView(views: [testButton, saveButton])
        buttons.spacing = 8
        buttons.translatesAutoresizingMaskIntoConstraints = false
        [grid, note, statusLabel, buttons].forEach { cv.addSubview($0) }
        NSLayoutConstraint.activate([
            grid.topAnchor.constraint(equalTo: cv.topAnchor, constant: 24),
            grid.leadingAnchor.constraint(equalTo: cv.leadingAnchor, constant: 24),
            grid.trailingAnchor.constraint(equalTo: cv.trailingAnchor, constant: -24),
            apiBaseURLField.widthAnchor.constraint(greaterThanOrEqualToConstant: 370),
            note.topAnchor.constraint(equalTo: grid.bottomAnchor, constant: 18),
            note.leadingAnchor.constraint(equalTo: grid.leadingAnchor),
            note.trailingAnchor.constraint(equalTo: grid.trailingAnchor),
            statusLabel.topAnchor.constraint(equalTo: note.bottomAnchor, constant: 10),
            statusLabel.leadingAnchor.constraint(equalTo: grid.leadingAnchor),
            statusLabel.trailingAnchor.constraint(equalTo: grid.trailingAnchor),
            buttons.trailingAnchor.constraint(equalTo: grid.trailingAnchor),
            buttons.bottomAnchor.constraint(equalTo: cv.bottomAnchor, constant: -20)
        ])
    }

    private var fieldConfiguration: LLMRefiner.Configuration {
        .init(baseURL: apiBaseURLField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines),
              apiKey: apiKeyField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines),
              model: modelField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines))
    }
    @objc private func clearKey() {
        apiKeyField.stringValue = ""
        showStatus("密钥已清空；点保存后生效。", success: nil)
    }
    @objc private func test() {
        testID = UUID()
        let id = testID
        testTask?.cancel()
        testButton.isEnabled = false
        showStatus("正在测试…", success: nil)
        // Testing uses the current fields without silently saving credentials.
        testTask = LLMRefiner.shared.refine("你好，这是语音识别纠错连接测试。", configuration: fieldConfiguration) { [weak self] result in
            guard let self, self.testID == id else { return }
            self.testButton.isEnabled = true
            self.testTask = nil
            switch result {
            case .success: self.showStatus("连接成功，模型已返回文字。", success: true)
            case .failure(let error): self.showStatus(error.localizedDescription, success: false)
            }
        }
    }
    @objc private func save() {
        let refiner = LLMRefiner.shared
        let config = fieldConfiguration
        do {
            try refiner.saveAPIKey(config.apiKey)
            refiner.apiBaseURL = config.baseURL
            refiner.model = config.model
            if !refiner.isConfigured { refiner.isEnabled = false }
            close()
        } catch { showStatus(error.localizedDescription, success: false) }
    }
    private func showStatus(_ text: String, success: Bool?) {
        statusLabel.stringValue = text
        statusLabel.textColor = success == true ? .systemGreen : success == false ? .systemRed : .secondaryLabelColor
    }
}
