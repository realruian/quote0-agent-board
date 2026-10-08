// swift-tools-version: 5.9
// The Quote/0 agent status board as one macOS app: BoardCore is everything that
// does not need a window server (so it can be tested), AgentBoard is the menu bar.

import PackageDescription

let package = Package(
    name: "AgentBoard",
    platforms: [.macOS(.v11)],
    targets: [
        .target(name: "BoardCore"),
        .executableTarget(name: "AgentBoard", dependencies: ["BoardCore"]),
        .testTarget(name: "BoardCoreTests", dependencies: ["BoardCore"]),
    ]
)
