import AVFoundation
import Speech
import AudioCapture

// Shared only for the immediate key-up decision while the audio queue is busy.
final class AudioStartupGate {
    private let lock = NSLock()
    private var stopped = false
    var permitsAudio: Bool { lock.lock(); defer { lock.unlock() }; return !stopped }
    func stop() { lock.lock(); stopped = true; lock.unlock() }
}

final class SpeechEngine {
    var onResult: ((UUID, String, Bool) -> Void)?
    var onError: ((UUID, String) -> Void)?
    var onAudioLevel: ((UUID, Float) -> Void)?
    // Audio lifecycle is serialized away from UI rendering. activeID belongs to
    // the main thread; worker-owned state is only accessed on audioQueue.
    private let audioQueue = DispatchQueue(label: "VoiceInput.audio.lifecycle", qos: .userInitiated)
    private var capture: VIAudioInputCapture?
    private var configurationObserver: NSObjectProtocol?
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var activeID: UUID?
    private var startupGate: AudioStartupGate?
    var locale = Locale(identifier: "zh-CN")

    static var hasPermissions: Bool {
        SFSpeechRecognizer.authorizationStatus() == .authorized && AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
    }
    static func requestPermissions(completion: @escaping (Bool, String?) -> Void) {
        SFSpeechRecognizer.requestAuthorization { status in
            guard status == .authorized else {
                DispatchQueue.main.async { completion(false, "请在系统设置 → 隐私与安全性 → 语音识别中允许 VoiceInput。") }
                return
            }
            AVCaptureDevice.requestAccess(for: .audio) { granted in
                DispatchQueue.main.async {
                    completion(granted, granted ? nil : "请在系统设置 → 隐私与安全性 → 麦克风中允许 VoiceInput。")
                }
            }
        }
    }
    func startRecording(id: UUID) {
        startupGate?.stop()
        let gate = AudioStartupGate()
        startupGate = gate
        activeID = id
        let locale = self.locale
        audioQueue.async { [weak self] in self?.startAudio(id: id, locale: locale, gate: gate) }
    }
    private func deliverError(id: UUID, message: String) {
        DispatchQueue.main.async { [weak self] in
            guard let self, self.activeID == id else { return }
            self.onError?(id, message)
        }
    }
    private func startAudio(id: UUID, locale: Locale, gate: AudioStartupGate) {
        cancelAudio()
        guard gate.permitsAudio else { return }
        guard let recognizer = SFSpeechRecognizer(locale: locale), recognizer.isAvailable else {
            deliverError(id: id, message: "当前语言的语音识别暂不可用，请检查网络和系统语言设置。")
            return
        }
        // A new engine follows the current hardware after sleep or an input change.
        let capture = VIAudioInputCapture()
        self.capture = capture
        let bufferRequest = SFSpeechAudioBufferRecognitionRequest()
        bufferRequest.shouldReportPartialResults = true
        bufferRequest.addsPunctuation = true
        request = bufferRequest
        task = recognizer.recognitionTask(with: bufferRequest) { [weak self] result, error in
            DispatchQueue.main.async {
                guard let self, self.activeID == id else { return }
                if let result {
                    self.onResult?(id, result.bestTranscription.formattedString, result.isFinal)
                } else if let error {
                    self.onError?(id, error.localizedDescription)
                }
            }
        }
        configurationObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: capture.engine, queue: nil
        ) { [weak self, weak capture] _ in
            self?.audioQueue.async { [weak self, weak capture] in
                guard let self, let capture, self.capture === capture,
                      !capture.engine.isRunning else { return }
                self.cancelAudio()
                self.deliverError(id: id, message: "麦克风设备已变化，请松开 Fn 后重新按住录音。")
            }
        }
        guard gate.permitsAudio else { stopAudio(); return }
        do { try capture.start { [weak self] buffer, _ in
            guard gate.permitsAudio else { return }
            bufferRequest.append(buffer)
            guard let data = buffer.floatChannelData?[0], buffer.frameLength > 0 else { return }
            var sum: Float = 0
            for i in 0..<Int(buffer.frameLength) { sum += data[i] * data[i] }
            let rms = sqrtf(sum / Float(buffer.frameLength))
            let level = max(Float(0), min(Float(1), (20 * log10(max(rms, 1e-6)) + 50) / 40))
            DispatchQueue.main.async {
                guard let self, self.activeID == id else { return }
                self.onAudioLevel?(id, level)
            }
        }
            if !gate.permitsAudio { stopAudio() }
        }
        catch {
            cancelAudio()
            deliverError(id: id, message: "麦克风启动失败：\(error.localizedDescription)")
        }
    }
    func stopRecording() {
        startupGate?.stop()
        audioQueue.async { [weak self] in self?.stopAudio() }
    }
    private func stopAudio() {
        if let observer = configurationObserver {
            NotificationCenter.default.removeObserver(observer)
            configurationObserver = nil
        }
        capture?.stop()
        capture = nil
        request?.endAudio()
    }
    func cancel() {
        activeID = nil
        startupGate?.stop(); startupGate = nil
        audioQueue.async { [weak self] in self?.cancelAudio() }
    }
    private func cancelAudio() {
        stopAudio()
        task?.cancel(); task = nil; request = nil
    }
    deinit {
        if let observer = configurationObserver { NotificationCenter.default.removeObserver(observer) }
        capture?.stop()
        task?.cancel()
    }
}
