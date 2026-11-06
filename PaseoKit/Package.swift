// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "PaseoKit",
    defaultLocalization: "zh-Hans",
    platforms: [.iOS(.v18), .macOS(.v15), .watchOS(.v11)],
    products: [
        .library(name: "PaseoKit", targets: ["PaseoKit"]),
        .library(name: "PaseoWatchBridge", targets: ["PaseoWatchBridge"]),
        .executable(name: "paseo-probe", targets: ["paseo-probe"]),
    ],
    targets: [
        .target(name: "PaseoKit", resources: [.process("Resources")]),
        // Foundation-only messages; the watch does not link the daemon/WebSocket client.
        .target(name: "PaseoWatchBridge"),
        .testTarget(name: "PaseoWatchBridgeTests", dependencies: ["PaseoWatchBridge"]),
        .executableTarget(name: "paseo-probe", dependencies: ["PaseoKit"]),
        .testTarget(
            name: "PaseoKitTests",
            dependencies: ["PaseoKit"],
            resources: [.copy("Fixtures")]
        ),
    ]
)
