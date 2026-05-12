import Foundation
import Testing
@testable import AIUsagesTrackersLib

@Suite("OutageWarningMigration")
@MainActor
struct OutageWarningMigrationTests {
    private func makeSuite() -> (UserDefaults, String) {
        let name = "ai-tracker-migration-test-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        return (defaults, name)
    }

    private func cleanUp(suiteName: String) {
        UserDefaults.standard.removePersistentDomain(forName: suiteName)
    }

    private func sampleSegment() -> MenuBarSegmentConfig {
        MenuBarSegmentConfig(
            vendor: .claude,
            account: .currentlyActive,
            metricName: "5h sessions (all models)",
            display: .timeWindow(TimeWindowDisplay(letter: "S"))
        )
    }

    @Test("legacy default-on without explicit flag enables warning with stored text")
    func defaultOnEnablesWarning() {
        let (defaults, name) = makeSuite()
        defer { cleanUp(suiteName: name) }

        // Legacy "initialized" flag absent: behaves like default-on.
        defaults.set("🛑", forKey: "ai-tracker.menuBarOutageWarningText")
        let prefs = InMemoryAppPreferences(
            menuBarSegments: [sampleSegment()],
            menuBarSegmentsInitialized: true
        )

        OutageWarningMigration.migrateIfNeeded(preferences: prefs, defaults: defaults)

        #expect(prefs.menuBarSegments.first?.showOutageWarning == true)
        #expect(prefs.menuBarSegments.first?.outageWarningText == "🛑")
        // Legacy keys cleared, migration flag set.
        #expect(defaults.object(forKey: "ai-tracker.menuBarOutageWarningText") == nil)
        #expect(defaults.bool(forKey: "ai-tracker.menuBarOutageWarningMigrationCompleted") == true)
    }

    @Test("legacy explicit-disable leaves segments untouched")
    func explicitDisableSkipsMigration() {
        let (defaults, name) = makeSuite()
        defer { cleanUp(suiteName: name) }

        defaults.set(true, forKey: "ai-tracker.menuBarOutageWarningEnabledInitialized")
        defaults.set(false, forKey: "ai-tracker.menuBarOutageWarningEnabled")
        let prefs = InMemoryAppPreferences(
            menuBarSegments: [sampleSegment()],
            menuBarSegmentsInitialized: true
        )

        OutageWarningMigration.migrateIfNeeded(preferences: prefs, defaults: defaults)

        #expect(prefs.menuBarSegments.first?.showOutageWarning == false)
    }

    @Test("legacy explicit-enable propagates stored text to all segments")
    func explicitEnableMigratesAll() {
        let (defaults, name) = makeSuite()
        defer { cleanUp(suiteName: name) }

        defaults.set(true, forKey: "ai-tracker.menuBarOutageWarningEnabledInitialized")
        defaults.set(true, forKey: "ai-tracker.menuBarOutageWarningEnabled")
        defaults.set("🚨", forKey: "ai-tracker.menuBarOutageWarningText")

        let prefs = InMemoryAppPreferences(
            menuBarSegments: [sampleSegment(), sampleSegment()],
            menuBarSegmentsInitialized: true
        )

        OutageWarningMigration.migrateIfNeeded(preferences: prefs, defaults: defaults)

        #expect(prefs.menuBarSegments.allSatisfy { $0.showOutageWarning })
        #expect(prefs.menuBarSegments.allSatisfy { $0.outageWarningText == "🚨" })
    }

    @Test("second call is a no-op")
    func idempotent() {
        let (defaults, name) = makeSuite()
        defer { cleanUp(suiteName: name) }

        let prefs = InMemoryAppPreferences(
            menuBarSegments: [sampleSegment()],
            menuBarSegmentsInitialized: true
        )

        OutageWarningMigration.migrateIfNeeded(preferences: prefs, defaults: defaults)
        // User intentionally turns the per-segment warning off after migration.
        prefs.menuBarSegments[0].showOutageWarning = false

        // Second invocation must respect that choice.
        OutageWarningMigration.migrateIfNeeded(preferences: prefs, defaults: defaults)
        #expect(prefs.menuBarSegments.first?.showOutageWarning == false)
    }

    @Test("missing stored text falls back to default ⚠️")
    func fallbackText() {
        let (defaults, name) = makeSuite()
        defer { cleanUp(suiteName: name) }

        let prefs = InMemoryAppPreferences(
            menuBarSegments: [sampleSegment()],
            menuBarSegmentsInitialized: true
        )

        OutageWarningMigration.migrateIfNeeded(preferences: prefs, defaults: defaults)

        #expect(prefs.menuBarSegments.first?.outageWarningText == "⚠️")
    }
}
