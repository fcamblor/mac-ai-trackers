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

    /// Encodes a single legacy `MenuBarSegmentConfig`-shaped payload as raw
    /// JSON. The migration operates on raw UserDefaults bytes (the type itself
    /// no longer exists at the API level), so the test seeds the legacy key
    /// directly with a dictionary that matches the historical shape.
    private func writeLegacySegment(to defaults: UserDefaults) {
        let dict: [String: Any] = [
            "id": UUID().uuidString,
            "vendor": "claude",
            "account": ["kind": "currently-active"],
            "metricName": "5h sessions (all models)",
            "display": [
                "kind": "time-window",
                "timeWindow": [
                    "showDot": true,
                    "showLetter": true,
                    "letter": "S",
                    "showPercent": true,
                    "showReset": true,
                    "hideResetMinutesWhenOverOneDay": true,
                    "showVendorIcon": false,
                ],
            ],
            "showOutageWarning": false,
            "outageWarningText": "",
        ]
        let data = try! JSONSerialization.data(withJSONObject: [dict], options: [])
        defaults.set(data, forKey: "ai-tracker.menuBarSegments")
    }

    private func readLegacySegments(from defaults: UserDefaults) -> [[String: Any]] {
        guard let data = defaults.data(forKey: "ai-tracker.menuBarSegments"),
              let array = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            return []
        }
        return array
    }

    @Test("legacy default-on without explicit flag enables warning with stored text")
    func defaultOnEnablesWarning() {
        let (defaults, name) = makeSuite()
        defer { cleanUp(suiteName: name) }

        // Legacy "initialized" flag absent: behaves like default-on.
        defaults.set("🛑", forKey: "ai-tracker.menuBarOutageWarningText")
        writeLegacySegment(to: defaults)

        OutageWarningMigration.migrateIfNeeded(defaults: defaults)

        let segments = readLegacySegments(from: defaults)
        #expect(segments.first?["showOutageWarning"] as? Bool == true)
        #expect(segments.first?["outageWarningText"] as? String == "🛑")
        #expect(defaults.object(forKey: "ai-tracker.menuBarOutageWarningText") == nil)
        #expect(defaults.bool(forKey: "ai-tracker.menuBarOutageWarningMigrationCompleted") == true)
    }

    @Test("legacy explicit-disable leaves segments untouched")
    func explicitDisableSkipsMigration() {
        let (defaults, name) = makeSuite()
        defer { cleanUp(suiteName: name) }

        defaults.set(true, forKey: "ai-tracker.menuBarOutageWarningEnabledInitialized")
        defaults.set(false, forKey: "ai-tracker.menuBarOutageWarningEnabled")
        writeLegacySegment(to: defaults)

        OutageWarningMigration.migrateIfNeeded(defaults: defaults)

        let segments = readLegacySegments(from: defaults)
        #expect(segments.first?["showOutageWarning"] as? Bool == false)
    }

    @Test("legacy explicit-enable propagates stored text to all segments")
    func explicitEnableMigratesAll() {
        let (defaults, name) = makeSuite()
        defer { cleanUp(suiteName: name) }

        defaults.set(true, forKey: "ai-tracker.menuBarOutageWarningEnabledInitialized")
        defaults.set(true, forKey: "ai-tracker.menuBarOutageWarningEnabled")
        defaults.set("🚨", forKey: "ai-tracker.menuBarOutageWarningText")
        writeLegacySegment(to: defaults)
        writeLegacySegment(to: defaults) // overwrite — we want one segment for simplicity

        OutageWarningMigration.migrateIfNeeded(defaults: defaults)

        let segments = readLegacySegments(from: defaults)
        #expect(segments.allSatisfy { ($0["showOutageWarning"] as? Bool) == true })
        #expect(segments.allSatisfy { ($0["outageWarningText"] as? String) == "🚨" })
    }

    @Test("second call is a no-op")
    func idempotent() {
        let (defaults, name) = makeSuite()
        defer { cleanUp(suiteName: name) }

        writeLegacySegment(to: defaults)

        OutageWarningMigration.migrateIfNeeded(defaults: defaults)
        // Manually flip the flag back to false to simulate a post-migration edit.
        var segments = readLegacySegments(from: defaults)
        if !segments.isEmpty {
            segments[0]["showOutageWarning"] = false
            let data = try! JSONSerialization.data(withJSONObject: segments, options: [])
            defaults.set(data, forKey: "ai-tracker.menuBarSegments")
        }

        // Second invocation must respect that choice.
        OutageWarningMigration.migrateIfNeeded(defaults: defaults)
        let after = readLegacySegments(from: defaults)
        #expect(after.first?["showOutageWarning"] as? Bool == false)
    }

    @Test("missing stored text falls back to default ⚠️")
    func fallbackText() {
        let (defaults, name) = makeSuite()
        defer { cleanUp(suiteName: name) }

        writeLegacySegment(to: defaults)

        OutageWarningMigration.migrateIfNeeded(defaults: defaults)

        let segments = readLegacySegments(from: defaults)
        #expect(segments.first?["outageWarningText"] as? String == "⚠️")
    }
}
