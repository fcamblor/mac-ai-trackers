import Foundation
import Testing
@testable import AIUsagesTrackersLib

@Suite("MenuBarChipsMigration")
@MainActor
struct MenuBarChipsMigrationTests {
    private static let legacySegmentsKey = "ai-tracker.menuBarSegments"
    private static let legacySegmentsInitializedKey = "ai-tracker.menuBarSegmentsInitialized"
    private static let legacySeparatorKey = "ai-tracker.menuBarSeparator"
    private static let completedKey = "ai-tracker.menuBarChipsMigrationCompleted"

    private func makeSuite() -> (UserDefaults, String) {
        let name = "ai-tracker-chips-migration-test-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        return (defaults, name)
    }

    private func cleanUp(suiteName: String) {
        UserDefaults.standard.removePersistentDomain(forName: suiteName)
    }

    /// Writes a legacy `MenuBarSegmentConfig`-shaped JSON entry. Mirrors the
    /// historical schema the production decoder no longer accepts directly.
    private func legacySegmentDict(
        vendor: String = "claude",
        metricName: String = "5h sessions (all models)",
        display: [String: Any]? = nil,
        showOutageWarning: Bool = false,
        outageWarningText: String = "⚠️"
    ) -> [String: Any] {
        let defaultDisplay: [String: Any] = [
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
        ]
        return [
            "id": UUID().uuidString,
            "vendor": vendor,
            "account": ["kind": "currently-active"],
            "metricName": metricName,
            "display": display ?? defaultDisplay,
            "showOutageWarning": showOutageWarning,
            "outageWarningText": outageWarningText,
        ]
    }

    private func writeLegacyPayload(_ segments: [[String: Any]], to defaults: UserDefaults) {
        let data = try! JSONSerialization.data(withJSONObject: segments, options: [])
        defaults.set(data, forKey: Self.legacySegmentsKey)
    }

    // MARK: - Happy path

    @Test("missing legacy payload still marks migration complete")
    func noLegacyData() {
        let (defaults, name) = makeSuite()
        defer { cleanUp(suiteName: name) }
        let prefs = InMemoryAppPreferences()

        MenuBarChipsMigration.migrateIfNeeded(preferences: prefs, defaults: defaults)

        #expect(prefs.menuBarChips.isEmpty)
        #expect(prefs.menuBarChipsInitialized == false)
        #expect(defaults.bool(forKey: Self.completedKey) == true)
    }

    @Test("single legacy segment becomes a one-segment chip")
    func singleSegmentMigrates() {
        let (defaults, name) = makeSuite()
        defer { cleanUp(suiteName: name) }
        let prefs = InMemoryAppPreferences()

        writeLegacyPayload([legacySegmentDict()], to: defaults)
        defaults.set(true, forKey: Self.legacySegmentsInitializedKey)

        MenuBarChipsMigration.migrateIfNeeded(preferences: prefs, defaults: defaults)

        #expect(prefs.menuBarChips.count == 1)
        let chip = prefs.menuBarChips[0]
        #expect(chip.vendor == .claude)
        #expect(chip.segments.count == 1)
        #expect(chip.segments[0].metricName == "5h sessions (all models)")
        #expect(prefs.menuBarChipsInitialized == true)
    }

    @Test("legacy showVendorIcon on the display promotes to chip level")
    func vendorIconPromotedToChipLevel() {
        let (defaults, name) = makeSuite()
        defer { cleanUp(suiteName: name) }
        let prefs = InMemoryAppPreferences()

        let withIcon = legacySegmentDict(display: [
            "kind": "time-window",
            "timeWindow": [
                "showDot": true,
                "showLetter": true,
                "letter": "S",
                "showPercent": true,
                "showReset": true,
                "hideResetMinutesWhenOverOneDay": true,
                "showVendorIcon": true,
            ],
        ])
        writeLegacyPayload([withIcon], to: defaults)

        MenuBarChipsMigration.migrateIfNeeded(preferences: prefs, defaults: defaults)

        #expect(prefs.menuBarChips.first?.showVendorIcon == true)
    }

    @Test("legacy outage fields propagate to the chip")
    func outageWarningPropagated() {
        let (defaults, name) = makeSuite()
        defer { cleanUp(suiteName: name) }
        let prefs = InMemoryAppPreferences()

        writeLegacyPayload(
            [legacySegmentDict(showOutageWarning: true, outageWarningText: "🚨")],
            to: defaults
        )

        MenuBarChipsMigration.migrateIfNeeded(preferences: prefs, defaults: defaults)

        let chip = prefs.menuBarChips.first
        #expect(chip?.showOutageWarning == true)
        #expect(chip?.outageWarningText == "🚨")
    }

    @Test("pay-as-you-go segment migrates without a vendor icon")
    func payAsYouGoMigrates() {
        let (defaults, name) = makeSuite()
        defer { cleanUp(suiteName: name) }
        let prefs = InMemoryAppPreferences()

        let payg = legacySegmentDict(
            metricName: "Monthly spend",
            display: ["kind": "pay-as-you-go"]
        )
        writeLegacyPayload([payg], to: defaults)

        MenuBarChipsMigration.migrateIfNeeded(preferences: prefs, defaults: defaults)

        let chip = prefs.menuBarChips.first
        #expect(chip?.showVendorIcon == false)
        #expect(chip?.segments.first?.display == .payAsYouGo)
    }

    @Test("multiple legacy segments produce one chip each (preserving order)")
    func multipleSegmentsBecomeMultipleChips() {
        let (defaults, name) = makeSuite()
        defer { cleanUp(suiteName: name) }
        let prefs = InMemoryAppPreferences()

        let first = legacySegmentDict(metricName: "5h sessions (all models)")
        let second = legacySegmentDict(metricName: "Weekly (all models)")
        writeLegacyPayload([first, second], to: defaults)

        MenuBarChipsMigration.migrateIfNeeded(preferences: prefs, defaults: defaults)

        #expect(prefs.menuBarChips.count == 2)
        #expect(prefs.menuBarChips[0].segments.first?.metricName == "5h sessions (all models)")
        #expect(prefs.menuBarChips[1].segments.first?.metricName == "Weekly (all models)")
    }

    // MARK: - Invariant repair

    @Test("legacy display with no visible element gets showLetter promoted")
    func emptyDisplayPromotesShowLetter() {
        let (defaults, name) = makeSuite()
        defer { cleanUp(suiteName: name) }
        let prefs = InMemoryAppPreferences()

        // Every visible toggle off — the chip-segment invariant would normally
        // reject this. The migration must repair instead of dropping the chip.
        let invisible = legacySegmentDict(display: [
            "kind": "time-window",
            "timeWindow": [
                "showDot": true,
                "showLetter": false,
                "letter": "S",
                "showPercent": false,
                "showReset": false,
                "hideResetMinutesWhenOverOneDay": true,
                "showVendorIcon": false,
            ],
        ])
        writeLegacyPayload([invisible], to: defaults)

        MenuBarChipsMigration.migrateIfNeeded(preferences: prefs, defaults: defaults)

        #expect(prefs.menuBarChips.count == 1)
        if case .timeWindow(let tw) = prefs.menuBarChips[0].segments[0].display {
            #expect(tw.showLetter == true)
            #expect(tw.hasAnyVisibleElement == true)
        } else {
            Issue.record("Expected time-window display variant")
        }
    }

    // MARK: - Failure handling

    @Test("corrupted payload is stashed under the backup key and chips end empty")
    func corruptedPayloadIsStashed() {
        let (defaults, name) = makeSuite()
        defer { cleanUp(suiteName: name) }
        let prefs = InMemoryAppPreferences()

        let garbage = Data("not valid json at all".utf8)
        defaults.set(garbage, forKey: Self.legacySegmentsKey)

        MenuBarChipsMigration.migrateIfNeeded(preferences: prefs, defaults: defaults)

        #expect(prefs.menuBarChips.isEmpty)
        #expect(defaults.data(forKey: MenuBarChipsMigration.corruptedBackupKey) == garbage)
        #expect(defaults.data(forKey: Self.legacySegmentsKey) == nil)
        #expect(defaults.bool(forKey: Self.completedKey) == true)
    }

    // MARK: - Initialized carry-over

    @Test("legacy initialized=true is carried across even when chips end empty")
    func initializedCarryOverWithEmptyChips() {
        let (defaults, name) = makeSuite()
        defer { cleanUp(suiteName: name) }
        let prefs = InMemoryAppPreferences()

        // The user deliberately removed every segment but kept the
        // "initialized" semantic. The seeder must not re-populate the list.
        writeLegacyPayload([], to: defaults)
        defaults.set(true, forKey: Self.legacySegmentsInitializedKey)

        MenuBarChipsMigration.migrateIfNeeded(preferences: prefs, defaults: defaults)

        #expect(prefs.menuBarChips.isEmpty)
        #expect(prefs.menuBarChipsInitialized == true)
    }

    @Test("non-empty chips always mark initialized=true even without legacy flag")
    func nonEmptyChipsForceInitialized() {
        let (defaults, name) = makeSuite()
        defer { cleanUp(suiteName: name) }
        let prefs = InMemoryAppPreferences()

        writeLegacyPayload([legacySegmentDict()], to: defaults)
        // legacySegmentsInitializedKey deliberately absent.

        MenuBarChipsMigration.migrateIfNeeded(preferences: prefs, defaults: defaults)

        #expect(prefs.menuBarChipsInitialized == true)
    }

    // MARK: - Cleanup & idempotence

    @Test("legacy keys are cleared after a successful run")
    func legacyKeysCleared() {
        let (defaults, name) = makeSuite()
        defer { cleanUp(suiteName: name) }
        let prefs = InMemoryAppPreferences()

        writeLegacyPayload([legacySegmentDict()], to: defaults)
        defaults.set(true, forKey: Self.legacySegmentsInitializedKey)
        defaults.set(" | ", forKey: Self.legacySeparatorKey)

        MenuBarChipsMigration.migrateIfNeeded(preferences: prefs, defaults: defaults)

        #expect(defaults.data(forKey: Self.legacySegmentsKey) == nil)
        #expect(defaults.object(forKey: Self.legacySegmentsInitializedKey) == nil)
        #expect(defaults.object(forKey: Self.legacySeparatorKey) == nil)
    }

    // MARK: - Ordering with OutageWarningMigration

    @Test("OutageWarningMigration → MenuBarChipsMigration propagates legacy global warning to chip")
    func outageThenChipsIntegration() {
        let (defaults, name) = makeSuite()
        defer { cleanUp(suiteName: name) }
        let prefs = InMemoryAppPreferences()

        // Legacy state: a segment without per-segment warning fields, plus the
        // global outage warning enabled with custom text. Mirrors what an old
        // build's UserDefaults would look like in the wild.
        let segment: [String: Any] = [
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
        writeLegacyPayload([segment], to: defaults)
        defaults.set(true, forKey: "ai-tracker.menuBarOutageWarningEnabledInitialized")
        defaults.set(true, forKey: "ai-tracker.menuBarOutageWarningEnabled")
        defaults.set("🚨", forKey: "ai-tracker.menuBarOutageWarningText")

        OutageWarningMigration.migrateIfNeeded(defaults: defaults)
        MenuBarChipsMigration.migrateIfNeeded(preferences: prefs, defaults: defaults)

        let chip = prefs.menuBarChips.first
        #expect(chip?.showOutageWarning == true)
        #expect(chip?.outageWarningText == "🚨")
    }

    @Test("inverted order leaves the global warning silently un-applied — documents the dependency")
    func chipsBeforeOutageLosesWarning() {
        let (defaults, name) = makeSuite()
        defer { cleanUp(suiteName: name) }
        let prefs = InMemoryAppPreferences()

        let segment: [String: Any] = [
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
        writeLegacyPayload([segment], to: defaults)
        defaults.set(true, forKey: "ai-tracker.menuBarOutageWarningEnabledInitialized")
        defaults.set(true, forKey: "ai-tracker.menuBarOutageWarningEnabled")
        defaults.set("🚨", forKey: "ai-tracker.menuBarOutageWarningText")

        // Wrong order: chips first → legacy segments key cleared → outage
        // migration can no longer reach the segment payload, so the chip ends
        // up without the warning the user had explicitly enabled.
        MenuBarChipsMigration.migrateIfNeeded(preferences: prefs, defaults: defaults)
        OutageWarningMigration.migrateIfNeeded(defaults: defaults)

        #expect(prefs.menuBarChips.first?.showOutageWarning == false)
    }

    @Test("second invocation is a no-op")
    func idempotent() {
        let (defaults, name) = makeSuite()
        defer { cleanUp(suiteName: name) }
        let prefs = InMemoryAppPreferences()

        writeLegacyPayload([legacySegmentDict()], to: defaults)
        MenuBarChipsMigration.migrateIfNeeded(preferences: prefs, defaults: defaults)
        let firstSnapshot = prefs.menuBarChips

        // Simulate a user clearing chips after the first migration; the second
        // invocation must respect that and not re-import anything.
        prefs.menuBarChips = []
        MenuBarChipsMigration.migrateIfNeeded(preferences: prefs, defaults: defaults)

        #expect(prefs.menuBarChips.isEmpty)
        #expect(!firstSnapshot.isEmpty)
    }
}
