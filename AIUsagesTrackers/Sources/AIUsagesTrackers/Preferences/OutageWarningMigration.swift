import Foundation

/// One-shot migration converting the legacy global "outage warning" preference
/// (`menuBarOutageWarningEnabled` + `menuBarOutageWarningText`) into per-segment
/// `showOutageWarning` / `outageWarningText` fields on `MenuBarSegmentConfig`.
///
/// Behaviour:
/// * If the user never explicitly set the flag, the legacy default was on, so we
///   activate the warning on every currently-configured segment using the stored
///   (or default) warning text.
/// * If the user explicitly disabled the flag, segments are left untouched.
/// * If the user explicitly enabled it, segments inherit the stored warning text.
/// * Once migrated, the legacy UserDefaults keys are removed and the migration
///   flag is set so subsequent launches no-op (preserving the user's per-segment
///   toggles).
@MainActor
public enum OutageWarningMigration {
    private static let legacyEnabledKey = "ai-tracker.menuBarOutageWarningEnabled"
    private static let legacyEnabledInitializedKey = "ai-tracker.menuBarOutageWarningEnabledInitialized"
    private static let legacyTextKey = "ai-tracker.menuBarOutageWarningText"
    private static let migrationCompletedKey = "ai-tracker.menuBarOutageWarningMigrationCompleted"

    public static func migrateIfNeeded(
        preferences: any AppPreferences,
        defaults: UserDefaults = .standard
    ) {
        guard !defaults.bool(forKey: migrationCompletedKey) else { return }

        let initialized = defaults.bool(forKey: legacyEnabledInitializedKey)
        let wasEnabled: Bool
        if initialized {
            wasEnabled = defaults.bool(forKey: legacyEnabledKey)
        } else {
            // Legacy default was on (opt-out); treat un-touched as enabled.
            wasEnabled = true
        }

        if wasEnabled {
            let storedText = defaults.string(forKey: legacyTextKey)
            let text = (storedText?.isEmpty == false)
                ? storedText!
                : MenuBarSegmentConfig.defaultOutageWarningText
            let segments = preferences.menuBarSegments
            if !segments.isEmpty {
                preferences.menuBarSegments = segments.map { config in
                    var copy = config
                    copy.showOutageWarning = true
                    copy.outageWarningText = text
                    return copy
                }
            }
        }

        defaults.removeObject(forKey: legacyEnabledKey)
        defaults.removeObject(forKey: legacyEnabledInitializedKey)
        defaults.removeObject(forKey: legacyTextKey)
        defaults.set(true, forKey: migrationCompletedKey)
    }
}
