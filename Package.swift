// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "PurifierBar",
    platforms: [.macOS(.v15)],
    targets: [
        .target(name: "PurifierCore"),
        .executableTarget(name: "PurifierBar", dependencies: ["PurifierCore"]),
        .executableTarget(name: "purifier-cli", dependencies: ["PurifierCore"]),
        .testTarget(name: "PurifierCoreTests", dependencies: ["PurifierCore"]),
    ]
)
