import Foundation

/// Versioned migration of the persisted preferences across releases, plus the
/// "show the upgrade changelog once" flag that goes with it.
///
/// Versions:
/// * `1` — every release up to and including 0.7.x (implicit: those builds
///   never wrote `storageSchemaVersion`).
/// * `2` — 0.8.0: Claude Desktop joins the `claude` account family. Settings
///   that identify an account by `vendor:account` must now cover both Claude
///   sources, otherwise an account the user hid or reordered as `claude:x`
///   reappears / jumps around as soon as its `claude-desktop:x` twin shows up.
///   Menu bar chips and chart series need no rewrite: 0.7.x could only store
///   `claude`, which is already the family-canonical vendor.
///
/// Must run BEFORE any seeder: the seeders write the "initialized" markers we
/// use to tell a pre-0.8 install apart from a brand-new one, and a fresh
/// install must neither be migrated nor shown the upgrade changelog.
@MainActor
public enum StorageSchemaMigration {
    public static let currentVersion = 2
    private static let legacyVersion = 1
    /// Release whose changelog is shown after a successful legacy → current migration.
    public static let changelogVersion = "0.8.0"

    public enum Outcome: Equatable, Sendable {
        case freshInstall
        case upToDate
        case migrated(fromVersion: Int)
    }

    /// Keys every pre-0.8 build writes on its first launch. Their presence,
    /// with no schema version stored, means we are upgrading rather than
    /// installing.
    private static let legacyInstallMarkerKeys: [AppPreferenceKeys] = [
        .chartConfigurationsInitialized,
        .menuBarChipsInitialized,
        .menuBarChipsMigrationCompleted,
        .menuBarOutageWarningMigrationCompleted,
        .refreshIntervalSeconds,
        .ignoredAccounts,
        .accountsOrder,
    ]

    @discardableResult
    public static func migrateIfNeeded(
        preferences: any AppPreferences,
        defaults: UserDefaults = .standard,
        logger: FileLogger = Loggers.app
    ) -> Outcome {
        let versionKey = AppPreferenceKeys.storageSchemaVersion.rawValue
        let storedVersion: Int
        if defaults.object(forKey: versionKey) != nil {
            storedVersion = defaults.integer(forKey: versionKey)
        } else if legacyInstallMarkerKeys.contains(where: { defaults.object(forKey: $0.rawValue) != nil }) {
            storedVersion = legacyVersion
        } else {
            defaults.set(currentVersion, forKey: versionKey)
            logger.log(.info, "StorageSchemaMigration: fresh install, schema v\(currentVersion)")
            return .freshInstall
        }

        guard storedVersion < currentVersion else { return .upToDate }

        if storedVersion < 2 {
            migrateToClaudeAccountFamily(preferences: preferences)
        }
        defaults.set(currentVersion, forKey: versionKey)
        defaults.set(changelogVersion, forKey: AppPreferenceKeys.pendingUpgradeChangelog.rawValue)
        logger.log(.info, "StorageSchemaMigration: migrated schema v\(storedVersion) → v\(currentVersion)")
        return .migrated(fromVersion: storedVersion)
    }

    /// Version whose upgrade changelog has not been acknowledged yet, if any.
    /// Kept until acknowledged so quitting before reading it re-shows it.
    public static func pendingChangelog(defaults: UserDefaults = .standard) -> String? {
        defaults.string(forKey: AppPreferenceKeys.pendingUpgradeChangelog.rawValue)
    }

    public static func acknowledgeChangelog(defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: AppPreferenceKeys.pendingUpgradeChangelog.rawValue)
    }

    // MARK: - v1 → v2

    private static func migrateToClaudeAccountFamily(preferences: any AppPreferences) {
        var ignored = preferences.ignoredAccounts
        for entry in preferences.ignoredAccounts where entry.vendor == .claude {
            let twin = IgnoredAccount(vendor: .claudeDesktop, account: entry.account)
            if !ignored.contains(twin) { ignored.append(twin) }
        }
        if ignored != preferences.ignoredAccounts {
            preferences.ignoredAccounts = ignored
        }

        let order = preferences.accountsOrder
        let existing = Set(order)
        let claudePrefix = "\(Vendor.claude.rawValue):"
        var migratedOrder: [String] = []
        for id in order {
            migratedOrder.append(id)
            guard id.hasPrefix(claudePrefix) else { continue }
            // Keep the Desktop twin right behind its CLI entry so the merged
            // card stays where the user dragged it.
            let twin = "\(Vendor.claudeDesktop.rawValue):\(id.dropFirst(claudePrefix.count))"
            if !existing.contains(twin) { migratedOrder.append(twin) }
        }
        if migratedOrder != order {
            preferences.accountsOrder = migratedOrder
        }
    }
}
