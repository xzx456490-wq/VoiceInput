// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "VoiceInput",
    platforms: [.macOS(.v14)],
    targets: [
        .target(name: "AudioCapture", path: "Sources/AudioCapture",
                publicHeadersPath: "include", cSettings: [.unsafeFlags(["-fobjc-arc"])]),
        .executableTarget(
            name: "VoiceInput",
            dependencies: ["AudioCapture"],
            path: "Sources/VoiceInput",
            resources: [.copy("Resources")]
        ),
        .target(name: "AudioCaptureTestSupport", dependencies: ["AudioCapture"],
                path: "Tests/AudioCaptureTestSupport", publicHeadersPath: "include",
                cSettings: [.unsafeFlags(["-fobjc-arc"])]),
        .testTarget(name: "VoiceInputTests", dependencies: ["VoiceInput", "AudioCapture", "AudioCaptureTestSupport"])
    ]
)
