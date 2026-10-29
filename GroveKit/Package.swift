// swift-tools-version: 6.0
import PackageDescription

// GroveKit is deliberately a standalone package with no dependencies: the whole
// meeting pipeline (capture → transcribe → enhance) is native Apple frameworks.
// Keeping it separate from the app target means a future cross-platform shell,
// or anyone else's app, can consume the engine on its own.
let package = Package(
    name: "GroveKit",
    // macOS 26 is the floor because SpeechAnalyzer and Foundation Models are
    // what make the zero-download, strictly-local promise possible. Supporting
    // older macOS means bundling whisper.cpp + a GGUF model; that's a deliberate
    // later choice, not a v1 requirement.
    platforms: [.macOS("26.0")],
    products: [
        .library(name: "GroveKit", targets: ["GroveKit"]),
        .executable(name: "grove", targets: ["grove"]),
    ],
    targets: [
        .target(
            name: "GroveKit",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .executableTarget(
            name: "grove",
            dependencies: ["GroveKit"],
            swiftSettings: [.swiftLanguageMode(.v5)],
            linkerSettings: [
                .unsafeFlags([
                    "-Xlinker", "-sectcreate",
                    "-Xlinker", "__TEXT",
                    "-Xlinker", "__info_plist",
                    "-Xlinker", "Sources/grove/Info.plist",
                ])
            ]
        ),
        .testTarget(
            name: "GroveKitTests",
            dependencies: ["GroveKit"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
