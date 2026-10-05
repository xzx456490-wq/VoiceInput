import AVFoundation
import Speech

final class SpeechEngine {
    var onResult: ((UUID, String, Bool) -> Void)?
    var onError: ((UUID, String) -> Void)?
    var onAudioLevel: ((UUID, Float) -> Void)?
    private let audioEngine = AVAudioEngine()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var activeID: UUID?
    private var tapInstalled = false
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
        cancel()
        activeID = id
        guard let recognizer = SFSpeechRecognizer(locale: locale), recognizer.isAvailable else {
            onError?(id, "当前语言的语音识别暂不可用，请检查网络和系统语言设置。")
            return
        }
        let input = audioEngine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            onError?(id, "未找到可用的麦克风。")
            return
        }
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
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
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
        tapInstalled = true
        audioEngine.prepare()
        do { try audioEngine.start() }
        catch {
            stopRecording()
            onError?(id, "麦克风启动失败：\(error.localizedDescription)")
        }
    }
    func stopRecording() {
        audioEngine.stop()
        if tapInstalled { audioEngine.inputNode.removeTap(onBus: 0); tapInstalled = false }
        request?.endAudio()
    }
    func cancel() {
        activeID = nil
        stopRecording()
        task?.cancel(); task = nil; request = nil
    }
}
