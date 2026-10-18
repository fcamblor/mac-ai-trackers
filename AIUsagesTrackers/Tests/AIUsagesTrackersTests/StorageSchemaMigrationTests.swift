import Foundation
import Testing
@testable import AIUsagesTrackersLib

@Suite("StorageSchemaMigration")
@MainActor
struct StorageSchemaMigrationTests {
    private let alice = AccountEmail(rawValue: "alice@example.com")
    private let bob = AccountEmail(rawValue: "bob@example.com")

    private func withSuite(_ body: (UserDefaults) throws -> Void) rethrows {
        let name = "ai-tracker-schema-migration-test-\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: name) else {
            Issue.record("Could not create UserDefaults suite \(name)")
            return
        }
        defer { UserDefaults.standard.removePersistentDomain(forName: name) }
        try body(defaults)
    }

    private func markAsLegacyInstall(_ defaults: UserDefaults) {
        defaults.set(true, forKey: AppPreferenceKeys.chartConfigurationsInitialized.rawValue)
    }

    @Test("fresh install records the current schema and shows no changelog")
    func freshInstall() {
        withSuite { defaults in
            let prefs = InMemoryAppPreferences()
            let outcome = StorageSchemaMigration.migrateIfNeeded(preferences: prefs, defaults: defaults)
            #expect(outcome == .freshInstall)
            #expect(defaults.integer(forKey: AppPreferenceKeys.storageSchemaVersion.rawValue) == StorageSchemaMigration.currentVersion)
            #expect(StorageSchemaMigration.pendingChangelog(defaults: defaults) == nil)
        }
    }

    @Test("fresh install stays without changelog on next launch")
    func freshInstallSecondLaunch() {
        withSuite { defaults in
            let prefs = InMemoryAppPreferences()
            StorageSchemaMigration.migrateIfNeeded(preferences: prefs, defaults: defaults)
            // Seeders run after the migration on first launch.
            markAsLegacyInstall(defaults)
            let outcome = StorageSchemaMigration.migrateIfNeeded(preferences: prefs, defaults: defaults)
            #expect(outcome == .upToDate)
            #expect(StorageSchemaMigration.pendingChangelog(defaults: defaults) == nil)
        }
    }

    @Test("0.7.x install is migrated and flags the changelog")
    func legacyInstallMigrates() {
        withSuite { defaults in
            markAsLegacyInstall(defaults)
            let prefs = InMemoryAppPreferences()
            let outcome = StorageSchemaMigration.migrateIfNeeded(preferences: prefs, defaults: defaults)
            #expect(outcome == .migrated(fromVersion: 1))
            #expect(StorageSchemaMigration.pendingChangelog(defaults: defaults) == StorageSchemaMigration.changelogVersion)
            #expect(defaults.integer(forKey: AppPreferenceKeys.storageSchemaVersion.rawValue) == StorageSchemaMigration.currentVersion)
        }
    }

    @Test("migration runs once; acknowledging clears the changelog for good")
    func idempotentAndAcknowledged() {
        withSuite { defaults in
            markAsLegacyInstall(defaults)
            let prefs = InMemoryAppPreferences(ignoredAccounts: [IgnoredAccount(vendor: .claude, account: alice)])
            StorageSchemaMigration.migrateIfNeeded(preferences: prefs, defaults: defaults)
            StorageSchemaMigration.acknowledgeChangelog(defaults: defaults)
            let outcome = StorageSchemaMigration.migrateIfNeeded(preferences: prefs, defaults: defaults)
            #expect(outcome == .upToDate)
            #expect(StorageSchemaMigration.pendingChangelog(defaults: defaults) == nil)
            #expect(prefs.ignoredAccounts.count == 2)
        }
    }

    @Test("ignored Claude accounts are extended to their Claude Desktop twin only")
    func ignoredAccountsExtended() {
        withSuite { defaults in
            markAsLegacyInstall(defaults)
            let prefs = InMemoryAppPreferences(ignoredAccounts: [
                IgnoredAccount(vendor: .claude, account: alice),
                IgnoredAccount(vendor: .codex, account: bob),
            ])
            StorageSchemaMigration.migrateIfNeeded(preferences: prefs, defaults: defaults)
            #expect(prefs.ignoredAccounts == [
                IgnoredAccount(vendor: .claude, account: alice),
                IgnoredAccount(vendor: .codex, account: bob),
                IgnoredAccount(vendor: .claudeDesktop, account: alice),
            ])
        }
    }

    @Test("accounts order keeps each Claude Desktop twin right after its CLI entry")
    func accountsOrderExtended() {
        withSuite { defaults in
            markAsLegacyInstall(defaults)
            let prefs = InMemoryAppPreferences(accountsOrder: [
                "codex:bob@example.com",
                "claude:alice@example.com",
                "copilot:bob@example.com",
            ])
            StorageSchemaMigration.migrateIfNeeded(preferences: prefs, defaults: defaults)
            #expect(prefs.accountsOrder == [
                "codex:bob@example.com",
                "claude:alice@example.com",
                "claude-desktop:alice@example.com",
                "copilot:bob@example.com",
            ])
        }
    }

    @Test("migration does not duplicate an already-present twin")
    func noDuplicateTwin() {
        withSuite { defaults in
            markAsLegacyInstall(defaults)
            let prefs = InMemoryAppPreferences(
                ignoredAccounts: [
                    IgnoredAccount(vendor: .claude, account: alice),
                    IgnoredAccount(vendor: .claudeDesktop, account: alice),
                ],
                accountsOrder: ["claude:alice@example.com", "claude-desktop:alice@example.com"]
            )
            StorageSchemaMigration.migrateIfNeeded(preferences: prefs, defaults: defaults)
            #expect(prefs.ignoredAccounts.count == 2)
            #expect(prefs.accountsOrder == ["claude:alice@example.com", "claude-desktop:alice@example.com"])
        }
    }

    @Test("menu bar chips and chart configurations are left untouched")
    func chipsAndChartsUntouched() {
        withSuite { defaults in
            markAsLegacyInstall(defaults)
            let charts = ChartConfigurationsSeeder.defaultConfigurations()
            let prefs = InMemoryAppPreferences(chartConfigurations: charts)
            let chipsBefore = prefs.menuBarChips
            StorageSchemaMigration.migrateIfNeeded(preferences: prefs, defaults: defaults)
            #expect(prefs.chartConfigurations == charts)
            #expect(prefs.menuBarChips == chipsBefore)
        }
    }
}
