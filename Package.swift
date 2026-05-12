// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "LocalNotch",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(url: "https://github.com/MrKai77/DynamicNotchKit", from: "1.0.0"),
        .package(url: "https://github.com/gonzalezreal/swift-markdown-ui", from: "2.4.0"),
    ],
    targets: [
        .executableTarget(
            name: "LocalNotch",
            dependencies: [
                .product(name: "DynamicNotchKit", package: "DynamicNotchKit"),
                .product(name: "MarkdownUI", package: "swift-markdown-ui"),
            ]
        )
    ]
)
