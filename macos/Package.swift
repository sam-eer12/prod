// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "BrokBot",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(
            name: "BrokBotCore",
            targets: ["BrokBotCore"]
        ),
        .executable(
            name: "BrokBotApp",
            targets: ["BrokBotApp"]
        )
    ],
    targets: [
        .target(
            name: "BrokBotCore"
        ),
        .executableTarget(
            name: "BrokBotApp",
            dependencies: ["BrokBotCore"],
            resources: [
                .process("Resources")
            ]
        ),
        .testTarget(
            name: "BrokBotCoreTests",
            dependencies: ["BrokBotCore"]
        )
    ]
)
