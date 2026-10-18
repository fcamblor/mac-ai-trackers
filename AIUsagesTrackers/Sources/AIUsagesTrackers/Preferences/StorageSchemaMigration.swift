import Foundation

/// Versioned migration of the persisted preferences across releases, plus the
/// "show the upgrade changelog once" flag that goes with it.
///
/// Versions:
/// * `1` — every release up to and including 0.7.x (implicit: those builds
///   never wrote `storageSchemaVersion`).
/// * `2` — 0.8.0: the Claude CLI vendor is renamed `claude` → `claude-tui`
///   and Claude Desktop joins the `claude` account family. Persisted settings
///   are re-saved with the new vendor value (decoding already maps the legacy
///   one, see `Vendor.legacyRawValueAliases`), and settings that identify an
///   account by `vendor:account` are extended to the Desktop twin, otherwise
///   an account the user hid or reordered reappears / jumps around as soon as
///   its `claude-desktop:x` twin shows up. A `PreMigrationBackup` is taken
///   first so the user can downgrade to 0.7.x.
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
        backup: PreMigrationBackup = .migrationTo080(),
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
            do {
                try backup.create(defaults: defaults)
                logger.log(.info, "StorageSchemaMigration: pre-migration backup written to \(backup.directory.path)")
            } catch {
                // Not fatal: the migrated app must still start. Only the
                // downgrade escape hatch is lost, so make it loud.
                logger.log(.error, "StorageSchemaMigration: pre-migration backup failed, downgrade restore unavailable: \(error)")
            }
            renameClaudeVendor(preferences: preferences, defaults: defaults, logger: logger)
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

    /// Decoding already turns legacy `claude` into `claude-tui`; writing the
    /// decoded values back persists the new raw value. `accountsOrder` holds
    /// plain `vendor:account` strings, so it is rewritten explicitly.
    private static func renameClaudeVendor(preferences: any AppPreferences, defaults: UserDefaults, logger: FileLogger) {
        // The getters fall back to `[]` on a decode failure; writing that back
        // would wipe the user's setting, so an empty result over stored bytes
        // is left untouched (decoding keeps mapping the legacy value anyway).
        func resave<T>(_ key: AppPreferenceKeys, _ value: [T], _ write: ([T]) -> Void) {
            if value.isEmpty, defaults.object(forKey: key.rawValue) != nil {
                logger.log(.warning, "StorageSchemaMigration: \(key.rawValue) decoded as empty, left as-is")
                return
            }
            write(value)
        }
        resave(.menuBarChips, preferences.menuBarChips) { preferences.menuBarChips = $0 }
        resave(.chartConfigurations, preferences.chartConfigurations) { preferences.chartConfigurations = $0 }
        resave(.ignoredAccounts, preferences.ignoredAccounts) { preferences.ignoredAccounts = $0 }
        preferences.accountsOrder = preferences.accountsOrder.map { id in
            guard let separator = id.firstIndex(of: ":") else { return id }
            let vendor = Vendor(normalizing: String(id[..<separator]))
            return vendor.rawValue + id[separator...]
        }
    }

    private static func migrateToClaudeAccountFamily(preferences: any AppPreferences) {
        var ignored = preferences.ignoredAccounts
        for entry in preferences.ignoredAccounts where entry.vendor == .claudeTUI {
            let twin = IgnoredAccount(vendor: .claudeDesktop, account: entry.account)
            if !ignored.contains(twin) { ignored.append(twin) }
        }
        if ignored != preferences.ignoredAccounts {
            preferences.ignoredAccounts = ignored
        }

        let order = preferences.accountsOrder
        let existing = Set(order)
        let claudePrefix = "\(Vendor.claudeTUI.rawValue):"
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
