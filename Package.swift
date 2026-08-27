// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "Guiliu",
    defaultLocalization: "zh-Hans",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "Guiliu", targets: ["Guiliu"])
    ],
    targets: [
        .target(
            name: "GuiliuCore",
            path: "Sources/GuiliuCore"
        ),
        .executableTarget(
            name: "Guiliu",
            dependencies: ["GuiliuCore"],
            path: "Sources/Guiliu"
        ),
        .testTarget(
            name: "GuiliuCoreTests",
            dependencies: ["GuiliuCore"],
            path: "Tests/GuiliuCoreTests"
        )
    ]
)
