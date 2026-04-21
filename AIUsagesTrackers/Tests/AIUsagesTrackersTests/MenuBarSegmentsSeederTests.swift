import Foundation
import Testing
@testable import AIUsagesTrackersLib

@Suite("MenuBarSegmentsSeeder")
struct MenuBarSegmentsSeederTests {
    @Test("seeds two default segments on fresh install")
    @MainActor
    func seedsFreshInstall() {
        let prefs = InMemoryAppPreferences()
        #expect(prefs.menuBarSegments.isEmpty)
        #expect(prefs.menuBarSegmentsInitialized == false)

        MenuBarSegmentsSeeder.seedIfNeeded(preferences: prefs)

        #expect(prefs.menuBarSegments.count == 2)
        #expect(prefs.menuBarSegmentsInitialized == true)
    }

    @Test("seeded segments target currently-active Claude account")
    @MainActor
    func seededSegmentsAreActiveClaude() {
        let prefs = InMemoryAppPreferences()
        MenuBarSegmentsSeeder.seedIfNeeded(preferences: prefs)

        for segment in prefs.menuBarSegments {
            #expect(segment.vendor == .claude)
            #expect(segment.account == .currentlyActive)
        }
    }

    @Test("seeded segments cover S and W with timeWindow display")
    @MainActor
    func seededMetricsAreSAndW() {
        let prefs = InMemoryAppPreferences()
        MenuBarSegmentsSeeder.seedIfNeeded(preferences: prefs)

        let metricNames = prefs.menuBarSegments.map(\.metricName)
        #expect(metricNames.contains("5h sessions (all models)"))
        #expect(metricNames.contains("Weekly (all models)"))

        for segment in prefs.menuBarSegments {
            guard case .timeWindow(let display) = segment.display else {
                Issue.record("Expected timeWindow display for metric \(segment.metricName)")
                continue
            }
            #expect(display.showDot)
            #expect(display.showLetter)
            #expect(display.showPercent)
            #expect(display.showReset)
        }
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
