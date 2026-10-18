import Foundation
import Testing
@testable import AIUsagesTrackersLib

@Suite("MenuBarChipsSeeder")
struct MenuBarChipsSeederTests {
    @Test("marks initialized without seeding any chip on fresh install")
    @MainActor
    func seedsFreshInstall() {
        let prefs = InMemoryAppPreferences()
        #expect(prefs.menuBarChips.isEmpty)
        #expect(prefs.menuBarChipsInitialized == false)

        MenuBarChipsSeeder.seedIfNeeded(preferences: prefs)

        #expect(prefs.menuBarChips.isEmpty)
        #expect(prefs.menuBarChipsInitialized == true)
    }

    @Test("default chips list is empty so onboarding can prompt the user")
    @MainActor
    func defaultChipsIsEmpty() {
        #expect(MenuBarChipsSeeder.defaultChips().isEmpty)
    }

    @Test("does not re-seed when already initialized")
    @MainActor
    func doesNotReSeedWhenInitialized() {
        let prefs = InMemoryAppPreferences(
            menuBarChips: [],
            menuBarChipsInitialized: true
        )
        MenuBarChipsSeeder.seedIfNeeded(preferences: prefs)

        #expect(prefs.menuBarChips.isEmpty)
    }

    @Test("preserves user chips when already initialized")
    @MainActor
    func preservesUserChips() {
        let existing = MenuBarChipConfig(
            vendor: .claudeTUI,
            segments: [
                MenuBarChipSegmentConfig(
                    account: .specific("me@example.com"),
                    metricName: "Custom",
                    display: .payAsYouGo
                )
            ]
        )
        let prefs = InMemoryAppPreferences(
            menuBarChips: [existing],
            menuBarChipsInitialized: true
        )
        MenuBarChipsSeeder.seedIfNeeded(preferences: prefs)

        #expect(prefs.menuBarChips == [existing])
    }
}
