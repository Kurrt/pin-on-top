// swift-tools-version: 6.0
// For the tests only. build.sh still builds the app from Sources/main.swift with swiftc.
import PackageDescription

let package = Package(
    name: "PinOnTop",
    platforms: [.macOS(.v14)],
    targets: [
        // The app's one file as a testable executable. Its top-level code doesn't run in tests.
        .executableTarget(name: "PinOnTop", path: "Sources", swiftSettings: [.swiftLanguageMode(.v5)]),
        .testTarget(name: "PinOnTopTests", dependencies: ["PinOnTop"]),
    ]
)
