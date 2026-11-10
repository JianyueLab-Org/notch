// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "NotchNotchAgents",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(name: "agents", path: "Sources/agents"),
    ]
)
