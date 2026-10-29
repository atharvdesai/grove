// swift-tools-version: 6.0
import PackageDescription

// The SwiftUI shell. Deliberately thin: everything that touches audio, speech,
// or storage lives in GroveKit, so the app is a view layer over an engine that is
// already exercised by the CLI and the test suite.
//
// This is a plain SwiftPM executable rather than an Xcode project. `Package.swift`
// reviews as text, builds on a stock CI runner with no Xcode GUI, and keeps the
// repo consistent with GroveKit. `scripts/bundle.sh` wraps the binary into
// Grove.app, which is what macOS needs for a menu-bar app and for TCC to read the
// usage descriptions.
let package = Package(
    name: "GroveApp",
    platforms: [.macOS("26.0")],
    products: [
        .executable(name: "GroveApp", targets: ["GroveApp"])
    ],
    dependencies: [
        .package(path: "../GroveKit")
    ],
    targets: [
        .executableTarget(
            name: "GroveApp",
            dependencies: [.product(name: "GroveKit", package: "GroveKit")],
            swiftSettings: [.swiftLanguageMode(.v5)]
        )
    ]
)
