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
            name: "SnapletSmokeTests",
            dependencies: ["SnapletCore"]
        )
    ]
)
