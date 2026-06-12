// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "ClaudeWatchCore",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "ClaudeWatchCore", targets: ["ClaudeWatchCore"]),
        .executable(name: "claude-watch-demo", targets: ["ClaudeWatchDemo"]),
        .executable(name: "claudewatch", targets: ["ClaudeWatchCLI"]),
    ],
    targets: [
        .target(
            name: "ClaudeWatchCore",
            path: "Sources/ClaudeWatchCore"
        ),
        .executableTarget(
            name: "ClaudeWatchDemo",
            dependencies: ["ClaudeWatchCore"],
            path: "Sources/ClaudeWatchDemo"
        ),
        .executableTarget(
            name: "ClaudeWatchCLI",
            dependencies: ["ClaudeWatchCore"],
            path: "Sources/ClaudeWatchCLI"
        ),
        .testTarget(
            name: "ClaudeWatchCoreTests",
            dependencies: ["ClaudeWatchCore"],
            path: "Tests/ClaudeWatchCoreTests"
        ),
    ]
)
