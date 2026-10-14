// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "Leeway",
    platforms: [.macOS(.v15)],
    dependencies: [
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.9.0"),
    ],
    targets: [
        // Everything that does not draw: discovery, fetchers, settings, cache. Tested by LeewayCoreTests.
        .target(
            name: "LeewayCore",
            path: "Sources/LeewayCore"),
        // The menu bar app: scenes, views, refresh scheduling, updates.
        .executableTarget(
            name: "Leeway",
            dependencies: [
                "LeewayCore",
                .product(name: "Sparkle", package: "Sparkle"),
            ],
            path: "Sources/Leeway"),
        .testTarget(
            name: "LeewayCoreTests",
            dependencies: ["LeewayCore"],
            path: "Tests/LeewayCoreTests"),
    ]
)
