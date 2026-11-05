// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "PaseoKit",
    defaultLocalization: "zh-Hans",
    platforms: [.iOS(.v18), .macOS(.v15)],
    products: [
        .library(name: "PaseoKit", targets: ["PaseoKit"]),
        .executable(name: "paseo-probe", targets: ["paseo-probe"]),
    ],
    targets: [
        .target(name: "PaseoKit", resources: [.process("Resources")]),
        .executableTarget(name: "paseo-probe", dependencies: ["PaseoKit"]),
        .testTarget(
            name: "PaseoKitTests",
            dependencies: ["PaseoKit"],
            resources: [.copy("Fixtures")]
        ),
    ]
)
