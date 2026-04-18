// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "AIUsagesTrackers",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(url: "https://github.com/SimplyDanny/SwiftLintPlugins", from: "0.57.0"),
    ],
    targets: [
        .target(
            name: "AIUsagesTrackersLib",
            path: "Sources/AIUsagesTrackers",
            plugins: [.plugin(name: "SwiftLintBuildToolPlugin", package: "SwiftLintPlugins")]
        ),
        .executableTarget(
            name: "AIUsagesTrackers",
            dependencies: ["AIUsagesTrackersLib"],
            path: "Sources/App",
            plugins: [.plugin(name: "SwiftLintBuildToolPlugin", package: "SwiftLintPlugins")]
        ),
        .testTarget(
            name: "AIUsagesTrackersTests",
            dependencies: ["AIUsagesTrackersLib"],
            path: "Tests/AIUsagesTrackersTests",
            plugins: [.plugin(name: "SwiftLintBuildToolPlugin", package: "SwiftLintPlugins")]
        ),
    ]
)
