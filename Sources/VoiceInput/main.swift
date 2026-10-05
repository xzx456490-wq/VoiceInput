import AppKit

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
