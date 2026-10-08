// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "GalaxyCompanionShared",
    platforms: [
        .iOS(.v17),
        .macOS(.v14)
    ],
    products: [
        .library(name: "GalaxyCompanionProtocol", targets: ["GalaxyCompanionProtocol"]),
        .library(name: "GalaxyCompanionSync", targets: ["GalaxyCompanionSync"]),
        .library(name: "GalaxyCompanionSimulator", targets: ["GalaxyCompanionSimulator"]),
        .library(name: "GalaxyCompanionHealth", targets: ["GalaxyCompanionHealth"])
    ],
    targets: [
        .target(name: "GalaxyCompanionProtocol"),
        .target(
            name: "GalaxyCompanionSync",
            dependencies: ["GalaxyCompanionProtocol"]
        ),
        .target(
            name: "GalaxyCompanionSimulator",
            dependencies: ["GalaxyCompanionProtocol", "GalaxyCompanionSync"]
        ),
        .target(
            name: "GalaxyCompanionHealth",
            dependencies: ["GalaxyCompanionProtocol"]
        ),
        .testTarget(
            name: "GalaxyCompanionProtocolTests",
            dependencies: ["GalaxyCompanionProtocol"]
        ),
        .testTarget(
            name: "GalaxyCompanionSyncTests",
            dependencies: [
                "GalaxyCompanionProtocol",
                "GalaxyCompanionSync",
                "GalaxyCompanionSimulator"
            ]
        ),
        .testTarget(
            name: "GalaxyCompanionHealthTests",
            dependencies: ["GalaxyCompanionHealth", "GalaxyCompanionProtocol"]
        )
    ]
)
