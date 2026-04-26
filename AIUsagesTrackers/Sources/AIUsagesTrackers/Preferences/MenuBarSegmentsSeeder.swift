import Foundation

/// Marks the menu bar segments preference as initialized on first launch without
/// presupposing the user's vendor or workflow. The label invites configuration
/// (see the unconfigured rendering in `MenuBarLabelRenderer`) until the user
/// adds their first segment via Settings. Idempotent: guarded by
/// `AppPreferences.menuBarSegmentsInitialized` so a user who intentionally
/// removed every segment isn't re-seeded on the next launch.
@MainActor
public enum MenuBarSegmentsSeeder {
    public static func defaultSegments() -> [MenuBarSegmentConfig] {
        []
    }

    public static func seedIfNeeded(preferences: any AppPreferences) {
        guard !preferences.menuBarSegmentsInitialized else { return }
        preferences.menuBarSegments = defaultSegments()
        preferences.menuBarSegmentsInitialized = true
    }
}
