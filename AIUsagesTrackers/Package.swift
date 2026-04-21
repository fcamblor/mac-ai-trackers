// swift-tools-version:6.0
import PackageDescription

// Isolated deinit is stable on Swift 6.2+ but still experimental on 6.1 (Xcode 16.x).
// Enabling it here keeps CI (older toolchain) aligned with local dev (newer toolchain).
let sharedSwiftSettings: [SwiftSetting] = [
    .enableExperimentalFeature("IsolatedDeinit"),
]

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
            swiftSettings: sharedSwiftSettings,
            plugins: [.plugin(name: "SwiftLintBuildToolPlugin", package: "SwiftLintPlugins")]
        ),
        .target(
            name: "AppIconKit",
            path: "Sources/AppIconKit",
            swiftSettings: sharedSwiftSettings,
            plugins: [.plugin(name: "SwiftLintBuildToolPlugin", package: "SwiftLintPlugins")]
        ),
        .executableTarget(
            name: "AIUsagesTrackers",
            dependencies: ["AIUsagesTrackersLib", "AppIconKit"],
            path: "Sources/App",
            swiftSettings: sharedSwiftSettings,
            plugins: [.plugin(name: "SwiftLintBuildToolPlugin", package: "SwiftLintPlugins")]
        ),
        .executableTarget(
            name: "IconExporter",
            dependencies: ["AppIconKit"],
            path: "Sources/IconExporter",
            swiftSettings: sharedSwiftSettings,
            plugins: [.plugin(name: "SwiftLintBuildToolPlugin", package: "SwiftLintPlugins")]
        ),
        .testTarget(
            name: "AIUsagesTrackersTests",
            dependencies: ["AIUsagesTrackersLib"],
            path: "Tests/AIUsagesTrackersTests",
            swiftSettings: sharedSwiftSettings,
            plugins: [.plugin(name: "SwiftLintBuildToolPlugin", package: "SwiftLintPlugins")]
        ),
    ]
)
