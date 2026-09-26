// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "claude-pets",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "ClaudePets",
            path: "Sources/ClaudePets",
            linkerSettings: [.linkedFramework("AppKit"), .linkedFramework("SpriteKit")]
        )
    ]
)
