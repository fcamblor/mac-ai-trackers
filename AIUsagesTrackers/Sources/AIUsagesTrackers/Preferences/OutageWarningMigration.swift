import Foundation

/// One-shot migration converting the legacy global "outage warning" preference
/// (`menuBarOutageWarningEnabled` + `menuBarOutageWarningText`) into per-segment
/// `showOutageWarning` / `outageWarningText` fields on the legacy
/// `MenuBarSegmentConfig` JSON payload still stored under
/// `ai-tracker.menuBarSegments`. Runs BEFORE `MenuBarChipsMigration`, which
/// then promotes those per-segment values to the chip level.
///
/// Behaviour:
/// * If the user never explicitly set the flag, the legacy default was on, so
///   the warning is activated on every currently-stored legacy segment.
/// * If the user explicitly disabled the flag, segments are left untouched.
/// * If the user explicitly enabled it, segments inherit the stored text.
/// * Once migrated, the legacy preference keys are removed and a completion
///   flag is set so subsequent launches no-op.
///
/// Operates on the raw `UserDefaults` payload because `AppPreferences` no
/// longer exposes the legacy `menuBarSegments` property — the chip model is
/// the only one the protocol acknowledges.
public enum OutageWarningMigration {
    private static let legacyEnabledKey = "ai-tracker.menuBarOutageWarningEnabled"
    private static let legacyEnabledInitializedKey = "ai-tracker.menuBarOutageWarningEnabledInitialized"
    private static let legacyTextKey = "ai-tracker.menuBarOutageWarningText"
    private static let migrationCompletedKey = "ai-tracker.menuBarOutageWarningMigrationCompleted"
    private static let legacySegmentsKey = "ai-tracker.menuBarSegments"
    /// Mirrors the default that `MenuBarChipConfig.defaultOutageWarningText`
    /// exposes — kept inline so this migration doesn't depend on a runtime
    /// constant whose value could change.
    private static let defaultOutageWarningText = "⚠️"

    public static func migrateIfNeeded(defaults: UserDefaults = .standard) {
        guard !defaults.bool(forKey: migrationCompletedKey) else { return }

        let initialized = defaults.bool(forKey: legacyEnabledInitializedKey)
        let wasEnabled: Bool
        if initialized {
            wasEnabled = defaults.bool(forKey: legacyEnabledKey)
        } else {
            // Legacy default was on (opt-out); treat un-touched as enabled.
            wasEnabled = true
        }

        if wasEnabled, let raw = defaults.data(forKey: legacySegmentsKey) {
            let storedText = defaults.string(forKey: legacyTextKey)
            let text = (storedText?.isEmpty == false) ? storedText! : defaultOutageWarningText
            if let mutated = applyWarning(to: raw, warningText: text) {
                defaults.set(mutated, forKey: legacySegmentsKey)
            }
        }

        defaults.removeObject(forKey: legacyEnabledKey)
        defaults.removeObject(forKey: legacyEnabledInitializedKey)
        defaults.removeObject(forKey: legacyTextKey)
        defaults.set(true, forKey: migrationCompletedKey)
    }

    /// Decodes the legacy `[MenuBarSegmentConfig]` JSON, sets every segment's
    /// `showOutageWarning = true` + `outageWarningText = text`, then re-encodes.
    /// Returns nil when the payload doesn't decode — `MenuBarChipsMigration`
    /// will see the same bytes and log its own decode failure.
    private static func applyWarning(to data: Data, warningText: String) -> Data? {
        guard var array = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]] else {
            return nil
        }
        for index in array.indices {
            array[index]["showOutageWarning"] = true
            array[index]["outageWarningText"] = warningText
        }
        return try? JSONSerialization.data(withJSONObject: array, options: [])
    }
}
