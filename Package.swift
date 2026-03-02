// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "Epoch",
    platforms: [
        .iOS(.v17),
        .macOS(.v14)
    ],
    products: [
        .library(name: "EpochCore", targets: ["EpochCore"]),
        .executable(name: "EpochApp", targets: ["EpochApp"])
    ],
    dependencies: [
        .package(url: "https://github.com/gonzalezreal/MarkdownUI.git", from: "2.4.1")
    ],
    targets: [
        .target(
            name: "EpochCore",
            path: "Sources/EpochCore"
        ),
        .executableTarget(
            name: "EpochApp",
            dependencies: [
                "EpochCore",
                .product(name: "MarkdownUI", package: "MarkdownUI")
            ],
            path: "Sources/EpochApp",
            resources: [
                .copy("Resources")
            ]
        ),
        .testTarget(
            name: "EpochCoreTests",
            dependencies: ["EpochCore"],
            path: "Tests/EpochCoreTests"
        ),
        .testTarget(
            name: "EpochAppTests",
            dependencies: ["EpochApp"],
            path: "Tests/EpochAppTests"
        )
    ]
)
