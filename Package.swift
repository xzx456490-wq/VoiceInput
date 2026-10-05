// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "VoiceInput",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "VoiceInput",
            path: "Sources/VoiceInput",
            resources: [.copy("Resources")]
        ),
        .testTarget(name: "VoiceInputTests", dependencies: ["VoiceInput"])
    ]
)
