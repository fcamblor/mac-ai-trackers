import Foundation

/// Seeds default menu bar segments on the first launch after install (or upgrade
/// from a pre-segments version). Idempotent: guarded by
/// `AppPreferences.menuBarSegmentsInitialized` so a user who intentionally
/// removed every segment isn't re-seeded on the next launch.
@MainActor
public enum MenuBarSegmentsSeeder {
    public static func defaultSegments() -> [MenuBarSegmentConfig] {
        [
            MenuBarSegmentConfig(
                vendor: .claude,
                account: .currentlyActive,
                metricName: "5h sessions (all models)",
                display: .timeWindow(TimeWindowDisplay(letter: "S"))
            ),
            MenuBarSegmentConfig(
                vendor: .claude,
                account: .currentlyActive,
                metricName: "Weekly (all models)",
                display: .timeWindow(TimeWindowDisplay(letter: "W"))
            ),
        ]
    }

    public static func seedIfNeeded(preferences: any AppPreferences) {
        guard !preferences.menuBarSegmentsInitialized else { return }
        preferences.menuBarSegments = defaultSegments()
        preferences.menuBarSegmentsInitialized = true
    }
}
