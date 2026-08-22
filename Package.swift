// swift-tools-version: 6.1

import PackageDescription

let package = Package(
    name: "M4Companion",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "MomentumCore", targets: ["MomentumCore"]),
        .library(name: "MomentumBluetooth", targets: ["MomentumBluetooth"]),
        .executable(name: "CoreTests", targets: ["CoreTests"]),
        .executable(name: "MomentumProbe", targets: ["MomentumProbe"])
    ],
    targets: [
        .target(name: "MomentumCore"),
        .target(
            name: "MomentumBluetooth",
            dependencies: ["MomentumCore"],
            linkerSettings: [.linkedFramework("IOBluetooth")]
        ),
        .executableTarget(name: "CoreTests", dependencies: ["MomentumCore", "MomentumBluetooth"]),
        .executableTarget(name: "MomentumProbe", dependencies: ["MomentumCore", "MomentumBluetooth"])
    ]
)
