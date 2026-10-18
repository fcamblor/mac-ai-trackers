import Foundation
import Testing
@testable import AIUsagesTrackersLib

@Suite("StorageSchemaMigration")
@MainActor
struct StorageSchemaMigrationTests {
    private let alice = AccountEmail(rawValue: "alice@example.com")
    private let bob = AccountEmail(rawValue: "bob@example.com")

    private func withSuite(_ body: (UserDefaults, PreMigrationBackup) throws -> Void) rethrows {
        let name = "ai-tracker-schema-migration-test-\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: name) else {
            Issue.record("Could not create UserDefaults suite \(name)")
            return
        }
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("schema-migration-test-\(UUID().uuidString)")
        let backup = PreMigrationBackup(
            directory: dir.appendingPathComponent("backup"),
            files: [dir.appendingPathComponent("usages.json")]
        )
        defer {
            UserDefaults.standard.removePersistentDomain(forName: name)
            try? FileManager.default.removeItem(at: dir) // best-effort test cleanup
        }
        try body(defaults, backup)
    }

    private func markAsLegacyInstall(_ defaults: UserDefaults) {
        defaults.set(true, forKey: AppPreferenceKeys.chartConfigurationsInitialized.rawValue)
    }

    @Test("fresh install records the current schema and shows no changelog")
    func freshInstall() {
        withSuite { defaults, backup in
            let prefs = InMemoryAppPreferences()
            let outcome = StorageSchemaMigration.migrateIfNeeded(preferences: prefs, defaults: defaults, backup: backup)
            #expect(outcome == .freshInstall)
            #expect(defaults.integer(forKey: AppPreferenceKeys.storageSchemaVersion.rawValue) == StorageSchemaMigration.currentVersion)
            #expect(StorageSchemaMigration.pendingChangelog(defaults: defaults) == nil)
        }
    }

    @Test("fresh install stays without changelog on next launch")
    func freshInstallSecondLaunch() {
        withSuite { defaults, backup in
            let prefs = InMemoryAppPreferences()
            StorageSchemaMigration.migrateIfNeeded(preferences: prefs, defaults: defaults, backup: backup)
            // Seeders run after the migration on first launch.
            markAsLegacyInstall(defaults)
            let outcome = StorageSchemaMigration.migrateIfNeeded(preferences: prefs, defaults: defaults, backup: backup)
            #expect(outcome == .upToDate)
            #expect(StorageSchemaMigration.pendingChangelog(defaults: defaults) == nil)
        }
    }

    @Test("0.7.x install is migrated and flags the changelog")
    func legacyInstallMigrates() {
        withSuite { defaults, backup in
            markAsLegacyInstall(defaults)
            let prefs = InMemoryAppPreferences()
            let outcome = StorageSchemaMigration.migrateIfNeeded(preferences: prefs, defaults: defaults, backup: backup)
            #expect(outcome == .migrated(fromVersion: 1))
            #expect(StorageSchemaMigration.pendingChangelog(defaults: defaults) == StorageSchemaMigration.changelogVersion)
            #expect(defaults.integer(forKey: AppPreferenceKeys.storageSchemaVersion.rawValue) == StorageSchemaMigration.currentVersion)
        }
    }

    @Test("migration runs once; acknowledging clears the changelog for good")
    func idempotentAndAcknowledged() {
        withSuite { defaults, backup in
            markAsLegacyInstall(defaults)
            let prefs = InMemoryAppPreferences(ignoredAccounts: [IgnoredAccount(vendor: .claudeTUI, account: alice)])
            StorageSchemaMigration.migrateIfNeeded(preferences: prefs, defaults: defaults, backup: backup)
            StorageSchemaMigration.acknowledgeChangelog(defaults: defaults)
            let outcome = StorageSchemaMigration.migrateIfNeeded(preferences: prefs, defaults: defaults, backup: backup)
            #expect(outcome == .upToDate)
            #expect(StorageSchemaMigration.pendingChangelog(defaults: defaults) == nil)
            #expect(prefs.ignoredAccounts.count == 2)
        }
    }

    @Test("ignored Claude accounts are extended to their Claude Desktop twin only")
    func ignoredAccountsExtended() {
        withSuite { defaults, backup in
            markAsLegacyInstall(defaults)
            let prefs = InMemoryAppPreferences(ignoredAccounts: [
                IgnoredAccount(vendor: .claudeTUI, account: alice),
                IgnoredAccount(vendor: .codex, account: bob),
            ])
            StorageSchemaMigration.migrateIfNeeded(preferences: prefs, defaults: defaults, backup: backup)
            #expect(prefs.ignoredAccounts == [
                IgnoredAccount(vendor: .claudeTUI, account: alice),
                IgnoredAccount(vendor: .codex, account: bob),
                IgnoredAccount(vendor: .claudeDesktop, account: alice),
            ])
        }
    }

    @Test("accounts order keeps each Claude Desktop twin right after its CLI entry")
    func accountsOrderExtended() {
        withSuite { defaults, backup in
            markAsLegacyInstall(defaults)
            let prefs = InMemoryAppPreferences(accountsOrder: [
                "codex:bob@example.com",
                "claude:alice@example.com",
                "copilot:bob@example.com",
            ])
            StorageSchemaMigration.migrateIfNeeded(preferences: prefs, defaults: defaults, backup: backup)
            #expect(prefs.accountsOrder == [
                "codex:bob@example.com",
                "claude-tui:alice@example.com",
                "claude-desktop:alice@example.com",
                "copilot:bob@example.com",
            ])
        }
    }

    @Test("migration does not duplicate an already-present twin")
    func noDuplicateTwin() {
        withSuite { defaults, backup in
            markAsLegacyInstall(defaults)
            let prefs = InMemoryAppPreferences(
                ignoredAccounts: [
                    IgnoredAccount(vendor: .claudeTUI, account: alice),
                    IgnoredAccount(vendor: .claudeDesktop, account: alice),
                ],
                accountsOrder: ["claude:alice@example.com", "claude-desktop:alice@example.com"]
            )
            StorageSchemaMigration.migrateIfNeeded(preferences: prefs, defaults: defaults, backup: backup)
            #expect(prefs.ignoredAccounts.count == 2)
            #expect(prefs.accountsOrder == ["claude-tui:alice@example.com", "claude-desktop:alice@example.com"])
        }
    }

    @Test("menu bar chips and chart configurations are left untouched")
    func chipsAndChartsUntouched() {
        withSuite { defaults, backup in
            markAsLegacyInstall(defaults)
            let charts = ChartConfigurationsSeeder.defaultConfigurations()
            let prefs = InMemoryAppPreferences(chartConfigurations: charts)
            let chipsBefore = prefs.menuBarChips
            StorageSchemaMigration.migrateIfNeeded(preferences: prefs, defaults: defaults, backup: backup)
            #expect(prefs.chartConfigurations == charts)
            #expect(prefs.menuBarChips == chipsBefore)
        }
    }

    @Test("legacy accounts order ids are renamed to claude-tui")
    func accountsOrderRenamed() {
        withSuite { defaults, backup in
            markAsLegacyInstall(defaults)
            let prefs = InMemoryAppPreferences(accountsOrder: ["claude:alice@example.com", "codex:bob@example.com"])
            StorageSchemaMigration.migrateIfNeeded(preferences: prefs, defaults: defaults, backup: backup)
            #expect(prefs.accountsOrder == [
                "claude-tui:alice@example.com",
                "claude-desktop:alice@example.com",
                "codex:bob@example.com",
            ])
        }
    }

    @Test("legacy install writes a pre-migration backup; fresh install does not")
    func backupOnlyOnLegacyMigration() {
        withSuite { defaults, backup in
            StorageSchemaMigration.migrateIfNeeded(preferences: InMemoryAppPreferences(), defaults: defaults, backup: backup)
            #expect(!backup.exists())
        }
        withSuite { defaults, backup in
            markAsLegacyInstall(defaults)
            StorageSchemaMigration.migrateIfNeeded(preferences: InMemoryAppPreferences(), defaults: defaults, backup: backup)
            #expect(backup.exists())
        }
    }
}

@Suite("PreMigrationBackup")
struct PreMigrationBackupTests {
    private func makeEnvironment() throws -> (UserDefaults, String, URL, PreMigrationBackup) {
        let name = "ai-tracker-backup-test-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("pre-migration-backup-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let backup = PreMigrationBackup(
            directory: dir.appendingPathComponent("backup"),
            files: [dir.appendingPathComponent("usages.json"), dir.appendingPathComponent("migrations.json")]
        )
        return (defaults, name, dir, backup)
    }

    private func cleanUp(_ name: String, _ dir: URL) {
        UserDefaults.standard.removePersistentDomain(forName: name)
        try? FileManager.default.removeItem(at: dir) // best-effort test cleanup
    }

    @Test("restore puts back preferences and files exactly as backed up")
    func roundTrip() throws {
        let (defaults, name, dir, backup) = try makeEnvironment()
        defer { cleanUp(name, dir) }
        let usages = dir.appendingPathComponent("usages.json")
        try Data(#"{"vendor":"claude"}"#.utf8).write(to: usages)
        defaults.set(42, forKey: "ai-tracker.refreshIntervalSeconds")
        defaults.set("keep-me", forKey: "unrelated.key")

        try backup.create(defaults: defaults)

        try Data(#"{"vendor":"claude-tui"}"#.utf8).write(to: usages)
        try Data("{}".utf8).write(to: dir.appendingPathComponent("migrations.json"))
        defaults.set(60, forKey: "ai-tracker.refreshIntervalSeconds")
        defaults.set(2, forKey: "ai-tracker.storageSchemaVersion")

        try backup.restore(defaults: defaults)

        #expect(try String(contentsOf: usages, encoding: .utf8) == #"{"vendor":"claude"}"#)
        // Absent at backup time → removed so the old release rebuilds it.
        #expect(!FileManager.default.fileExists(atPath: dir.appendingPathComponent("migrations.json").path))
        #expect(defaults.integer(forKey: "ai-tracker.refreshIntervalSeconds") == 42)
        #expect(defaults.object(forKey: "ai-tracker.storageSchemaVersion") == nil)
        #expect(defaults.string(forKey: "unrelated.key") == "keep-me")
    }

    @Test("restore without a backup fails with the manifest path")
    func restoreMissing() throws {
        let (defaults, name, dir, backup) = try makeEnvironment()
        defer { cleanUp(name, dir) }
        #expect(!backup.exists())
        #expect(throws: PreMigrationBackupError.self) {
            try backup.restore(defaults: defaults)
        }
    }
}

@Suite("Vendor legacy raw values")
struct VendorLegacyRawValueTests {
    @Test("legacy claude decodes as claude-tui and re-encodes with the new value")
    func legacyClaudeDecodes() throws {
        let decoded = try JSONDecoder().decode([Vendor].self, from: Data(#"["claude","codex"]"#.utf8))
        #expect(decoded == [.claudeTUI, .codex])
        #expect(String(decoding: try JSONEncoder().encode(decoded), as: UTF8.self) == #"["claude-tui","codex"]"#)
    }

    @Test("normalizing maps the legacy value and keeps others")
    func normalizing() {
        #expect(Vendor(normalizing: "claude") == .claudeTUI)
        #expect(Vendor(normalizing: "claude-desktop") == .claudeDesktop)
    }
}
