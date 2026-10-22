// swift-tools-version: 6.4
import PackageDescription

let package = Package(
    name: "ContactBridge",
    platforms: [.macOS(.v27)],
    products: [
        .library(name: "ContactBridgeCore", targets: ["ContactBridgeCore"]),
        .executable(name: "ContactBridgeApp", targets: ["ContactBridgeApp"]),
    ],
    targets: [
        .target(name: "ContactBridgeCore"),
        .executableTarget(name: "ContactBridgeApp", dependencies: ["ContactBridgeCore"]),
        .testTarget(
            name: "ContactBridgeCoreTests",
            dependencies: ["ContactBridgeCore"],
            resources: [.process("Fixtures")]
        ),
    ]
)
