// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Transcribe",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "TranscribeApp", targets: ["TranscribeApp"]),
        .library(name: "TranscribeKit", targets: ["TranscribeKit"]),
    ],
    targets: [
        // CLI process, NDJSON events, queue state. No SwiftUI, so it is testable headless.
        // The app icon SVGs in gui/icons as a resource bundle (one copy; SwiftPM won't follow symlinks).
        .target(
            name: "AppIconResources",
            path: "icons",
            exclude: ["README.md"],
            resources: [.copy("a3b-lcd-clay.svg"), .copy("a3b-crt-gold.svg"), .copy("a3b-ribbon-ivory.svg"),
                        .copy("a3b-led-navy.svg"), .copy("a3d-bars.svg"), .copy("h3-olive.svg"),
                        .copy("h3b.svg"), .copy("h5.svg")]
        ),
        .target(name: "TranscribeKit", dependencies: ["AppIconResources"]),
        .executableTarget(name: "TranscribeApp", dependencies: ["TranscribeKit"]),
        .testTarget(
            name: "TranscribeKitTests",
            dependencies: ["TranscribeKit"],
            exclude: ["Fixtures"]
        ),
    ]
)
