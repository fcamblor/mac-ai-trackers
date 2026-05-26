import Foundation

/// Marks the menu bar chips preference as initialized on first launch without
/// presupposing the user's vendor or workflow. The label invites configuration
/// (see the unconfigured rendering in `MenuBarLabelRenderer`) until the user
/// adds their first chip via Settings. Idempotent: guarded by
/// `AppPreferences.menuBarChipsInitialized` so a user who intentionally
/// removed every chip isn't re-seeded on the next launch.
@MainActor
public enum MenuBarChipsSeeder {
    public static func defaultChips() -> [MenuBarChipConfig] {
        []
    }

    public static func seedIfNeeded(preferences: any AppPreferences) {
        guard !preferences.menuBarChipsInitialized else { return }
        preferences.menuBarChips = defaultChips()
        preferences.menuBarChipsInitialized = true
    }
}
