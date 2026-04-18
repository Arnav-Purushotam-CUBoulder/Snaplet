// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "Snaplet",
    platforms: [
        .iOS(.v17),
        .macOS(.v14)
    ],
    products: [
        .library(
            name: "SnapletCore",
            targets: ["SnapletCore"]
        ),
        .executable(
            name: "SnapletAdmin",
            targets: ["SnapletAdmin"]
        ),
        .executable(
            name: "SnapletSmokeTests",
            targets: ["SnapletSmokeTests"]
        )
    ],
    targets: [
        .target(
            name: "SnapletCore",
            exclude: ["Assets.xcassets"]
        ),
        .executableTarget(
            name: "SnapletAdmin",
            dependencies: ["SnapletCore"]
        ),
        .executableTarget(
            name: "SnapletSmokeTests",
            dependencies: ["SnapletCore"]
        )
    ]
)
