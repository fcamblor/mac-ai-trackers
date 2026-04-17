// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "AIUsagesTrackers",
    platforms: [.macOS(.v14)],
    targets: [
        .target(
            name: "AIUsagesTrackersLib",
            path: "Sources/AIUsagesTrackers",
            exclude: ["AIUsagesTrackersApp.swift"]
        ),
        .executableTarget(
            name: "AIUsagesTrackers",
            dependencies: ["AIUsagesTrackersLib"],
            path: "Sources/App"
        ),
        .testTarget(
            name: "AIUsagesTrackersTests",
            dependencies: ["AIUsagesTrackersLib"],
            path: "Tests/AIUsagesTrackersTests"
        ),
    ]
)
