import AppKit
import AVFoundation
import Speech
import ServiceManagement
import AudioCapture

// Read-only diagnostics bypass normal launch UI and never request permissions.
if CommandLine.arguments.contains("--verify-input-permissions") {
    print("microphone=\(AVCaptureDevice.authorizationStatus(for: .audio) == .authorized)")
    print("speech=\(SFSpeechRecognizer.authorizationStatus() == .authorized)")
    print("device_control=\(AXIsProcessTrusted())")
    print("login_item_status=\(SMAppService.mainApp.status.rawValue)")
    exit(0)
}
if CommandLine.arguments.contains("--verify-audio-capture") {
    guard AVCaptureDevice.authorizationStatus(for: .audio) == .authorized else {
        fputs("Microphone permission not granted; diagnostic did not request it.\n", stderr)
        exit(2)
    }
    do {
        for _ in 0..<10 {
            let capture = VIAudioInputCapture()
            try capture.start { _, _ in } // Discard samples; no files or recognition.
            Thread.sleep(forTimeInterval: 0.15)
            capture.stop()
        }
        print("PASS: 10 real input starts/stops without storing audio")
        exit(0)
    } catch {
        fputs("FAIL: audio capture: \(error.localizedDescription)\n", stderr)
        exit(1)
    }
}

let app = NSApplication.shared
var performanceCheck: AnyObject?
if let index = CommandLine.arguments.firstIndex(of: "--benchmark-ui"), CommandLine.arguments.count > index + 2 {
    if #available(macOS 26.0, *) {
        do {
            app.setActivationPolicy(.accessory)
            let check = try SiriPerformanceCheck(mode: CommandLine.arguments[index+1], output: URL(fileURLWithPath: CommandLine.arguments[index+2]))
            performanceCheck = check; check.run(); app.run(); exit(0)
        } catch { fputs("FAIL: UI benchmark: \(error)\n", stderr); exit(1) }
    } else { fputs("Native glass requires macOS 26 or newer\n", stderr); exit(1) }
}
if CommandLine.arguments.contains("--verify-siri-renderer") {
    do {
        let renderer = try SiriMetalRenderer()
        renderer.progress = 1; renderer.intro = 2; renderer.energy = CommandLine.arguments.contains("--idle") ? 0 : 0.72; renderer.elapsed = 2.5
        let frame = try renderer.snapshot(size: CGSize(width: 260, height: 180))
        let url = URL(fileURLWithPath: "/private/tmp/voiceinput-siri-formal.png")
        try NSBitmapImageRep(cgImage: frame).representation(using: .png, properties: [:])!.write(to: url)
        print("PASS: bundled Metal renderer, native recording size, frame written to \(url.path)")
        exit(0)
    } catch { fputs("FAIL: bundled Siri renderer: \(error)\n", stderr); exit(1) }
}
app.setActivationPolicy(.accessory)

let delegate = AppDelegate()
app.delegate = delegate
app.run()
