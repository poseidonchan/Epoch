// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "LabOS",
    platforms: [
        .iOS(.v17),
        .macOS(.v14)
    ],
    products: [
        .library(name: "LabOSCore", targets: ["LabOSCore"]),
        .executable(name: "LabOSApp", targets: ["LabOSApp"])
    ],
    dependencies: [
        .package(url: "https://github.com/gonzalezreal/MarkdownUI.git", from: "2.4.1")
    ],
    targets: [
        .target(
            name: "LabOSCore",
            path: "Sources/LabOSCore"
        ),
        .executableTarget(
            name: "LabOSApp",
            dependencies: [
                "LabOSCore",
                .product(name: "MarkdownUI", package: "MarkdownUI")
            ],
            path: "Sources/LabOSApp",
            resources: [
                .copy("Resources")
            ]
        ),
        .testTarget(
            name: "LabOSCoreTests",
            dependencies: ["LabOSCore"],
            path: "Tests/LabOSCoreTests"
        )
    ]
)
