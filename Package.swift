// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "XBloom",
    platforms: [
        .macOS(.v13),
        .iOS(.v17),
    ],
    products: [
        .library(name: "XBloomCore", targets: ["XBloomCore"]),
    ],
    targets: [
        .target(
            name: "XBloomCore",
            path: "Sources/XBloomCore"
        ),
        .testTarget(
            name: "XBloomCoreTests",
            dependencies: ["XBloomCore"],
            path: "Tests/XBloomCoreTests"
        ),
    ]
)
