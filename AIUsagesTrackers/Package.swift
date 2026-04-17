// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "AIUsagesTrackers",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "AIUsagesTrackers",
            path: "Sources/AIUsagesTrackers"
        )
    ]
)
