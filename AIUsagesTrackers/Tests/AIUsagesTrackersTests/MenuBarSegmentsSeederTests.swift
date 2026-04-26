import Foundation
import Testing
@testable import AIUsagesTrackersLib

@Suite("MenuBarSegmentsSeeder")
struct MenuBarSegmentsSeederTests {
    @Test("marks initialized without seeding any segment on fresh install")
    @MainActor
    func seedsFreshInstall() {
        let prefs = InMemoryAppPreferences()
        #expect(prefs.menuBarSegments.isEmpty)
        #expect(prefs.menuBarSegmentsInitialized == false)

        MenuBarSegmentsSeeder.seedIfNeeded(preferences: prefs)

        #expect(prefs.menuBarSegments.isEmpty)
        #expect(prefs.menuBarSegmentsInitialized == true)
    }

    @Test("default segments list is empty so onboarding can prompt the user")
    @MainActor
    func defaultSegmentsIsEmpty() {
        #expect(MenuBarSegmentsSeeder.defaultSegments().isEmpty)
    }

    @Test("does not re-seed when already initialized")
    @MainActor
    func doesNotReSeedWhenInitialized() {
        let prefs = InMemoryAppPreferences(
            menuBarSegments: [],
            menuBarSegmentsInitialized: true
        )
        MenuBarSegmentsSeeder.seedIfNeeded(preferences: prefs)

        #expect(prefs.menuBarSegments.isEmpty)
    }

    @Test("preserves user segments when already initialized")
    @MainActor
    func preservesUserSegments() {
        let existing = MenuBarSegmentConfig(
            vendor: .claude,
            account: .specific("me@example.com"),
            metricName: "Custom",
            display: .payAsYouGo
        )
        let prefs = InMemoryAppPreferences(
            menuBarSegments: [existing],
            menuBarSegmentsInitialized: true
        )
        MenuBarSegmentsSeeder.seedIfNeeded(preferences: prefs)

        #expect(prefs.menuBarSegments == [existing])
    }
}
