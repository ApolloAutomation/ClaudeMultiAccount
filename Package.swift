// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "ClaudeMultiAccount",
    platforms: [.macOS(.v26)],
    products: [
        .executable(name: "ClaudeMultiAccount", targets: ["ClaudeMultiAccount"]),
        .executable(name: "ProfileAgent", targets: ["ProfileAgent"]),
    ],
    targets: [
        .target(name: "CMACore"),
        .target(name: "CMASystem", dependencies: ["CMACore"]),
        .executableTarget(name: "ProfileAgent", dependencies: ["CMACore", "CMASystem"]),
        .executableTarget(name: "ClaudeMultiAccount", dependencies: ["CMACore", "CMASystem"]),
        .testTarget(name: "CMACoreTests", dependencies: ["CMACore"]),
        .testTarget(name: "CMASystemTests", dependencies: ["CMASystem", "CMACore"]),
    ]
)
