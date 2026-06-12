// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "ClaudeWatchCore",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "ClaudeWatchCore", targets: ["ClaudeWatchCore"]),
        .executable(name: "claude-watch-demo", targets: ["ClaudeWatchDemo"]),
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
        .testTarget(
            name: "ClaudeWatchCoreTests",
            dependencies: ["ClaudeWatchCore"],
            path: "Tests/ClaudeWatchCoreTests"
        ),
    ]
)
