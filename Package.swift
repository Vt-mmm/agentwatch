// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "AgentWatchCore",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "AgentWatchCore", targets: ["AgentWatchCore"]),
        .executable(name: "agent-watch-demo", targets: ["AgentWatchDemo"]),
        .executable(name: "agentwatch", targets: ["AgentWatchCLI"]),
    ],
    targets: [
        .target(
            name: "AgentWatchCore",
            path: "Sources/AgentWatchCore",
            resources: [.process("Resources")]
        ),
        .executableTarget(
            name: "AgentWatchDemo",
            dependencies: ["AgentWatchCore"],
            path: "Sources/AgentWatchDemo"
        ),
        .executableTarget(
            name: "AgentWatchCLI",
            dependencies: ["AgentWatchCore"],
            path: "Sources/AgentWatchCLI"
        ),
        .testTarget(
            name: "AgentWatchCoreTests",
            dependencies: ["AgentWatchCore"],
            path: "Tests/AgentWatchCoreTests"
        ),
    ]
)
