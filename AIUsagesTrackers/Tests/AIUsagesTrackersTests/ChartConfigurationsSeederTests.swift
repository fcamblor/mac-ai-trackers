import Foundation
import Testing
@testable import AIUsagesTrackersLib

@Suite("ChartConfigurationsSeeder")
struct ChartConfigurationsSeederTests {
    @Test("creates all-available chart on fresh install")
    @MainActor
    func seedsFreshInstall() {
        let prefs = InMemoryAppPreferences()
        #expect(prefs.chartConfigurations.isEmpty)
        #expect(prefs.chartConfigurationsInitialized == false)

        ChartConfigurationsSeeder.seedIfNeeded(preferences: prefs)

        #expect(prefs.chartConfigurations.count == 1)
        #expect(prefs.chartConfigurations[0].title == "All available metrics")
        #expect(prefs.chartConfigurations[0].selection == .allAvailable)
        #expect(prefs.chartConfigurationsInitialized == true)
    }

    @Test("does not reseed when already initialized")
    @MainActor
    func doesNotReseedWhenInitialized() {
        let prefs = InMemoryAppPreferences(
            chartConfigurations: [],
            chartConfigurationsInitialized: true
        )

        ChartConfigurationsSeeder.seedIfNeeded(preferences: prefs)

        #expect(prefs.chartConfigurations.isEmpty)
    }

    @Test("preserves existing chart list")
    @MainActor
    func preservesExistingList() {
        let existing = ChartConfiguration(title: "Custom", selection: .custom([]))
        let prefs = InMemoryAppPreferences(
            chartConfigurations: [existing],
            chartConfigurationsInitialized: false
        )

        ChartConfigurationsSeeder.seedIfNeeded(preferences: prefs)

        #expect(prefs.chartConfigurations == [existing])
        #expect(prefs.chartConfigurationsInitialized == true)
    }
}
