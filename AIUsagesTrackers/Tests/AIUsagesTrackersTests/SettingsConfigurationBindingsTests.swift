import Foundation
import Testing
@testable import AIUsagesTrackers
@testable import AIUsagesTrackersLib

@MainActor
@Suite("Settings configuration bindings")
struct SettingsConfigurationBindingsTests {
    @Test("menu bar segment binding read survives target deletion")
    func menuBarSegmentBindingSurvivesTargetDeletion() {
        let first = MenuBarSegmentConfig(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000101")!,
            vendor: .claude,
            account: .currentlyActive,
            metricName: "5h sessions (all models)",
            display: .timeWindow(TimeWindowDisplay(letter: "S"))
        )
        let target = MenuBarSegmentConfig(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000102")!,
            vendor: .claude,
            account: .currentlyActive,
            metricName: "Weekly (all models)",
            display: .timeWindow(TimeWindowDisplay(letter: "W"))
        )
        let preferences = InMemoryAppPreferences(menuBarSegments: [first, target])

        let binding = SettingsConfigurationBindings.menuBarSegment(
            preferences: preferences,
            segmentID: target.id
        )
        #expect(binding != nil)
        guard let binding else { return }

        preferences.menuBarSegments.removeAll { $0.id == target.id }

        #expect(binding.wrappedValue == target)
        var edited = binding.wrappedValue
        edited.metricName = "Edited after deletion"
        binding.wrappedValue = edited
        #expect(preferences.menuBarSegments == [first])
    }

    @Test("chart configuration binding read survives target deletion")
    func chartConfigurationBindingSurvivesTargetDeletion() {
        let first = ChartConfiguration(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000201")!,
            title: "All metrics",
            selection: .allAvailable
        )
        let target = ChartConfiguration(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000202")!,
            title: "Custom",
            selection: .custom([])
        )
        let preferences = InMemoryAppPreferences(chartConfigurations: [first, target])

        let binding = SettingsConfigurationBindings.chartConfiguration(
            preferences: preferences,
            configurationID: target.id
        )
        #expect(binding != nil)
        guard let binding else { return }

        preferences.chartConfigurations.removeAll { $0.id == target.id }

        #expect(binding.wrappedValue == target)
        var edited = binding.wrappedValue
        edited.title = "Edited after deletion"
        binding.wrappedValue = edited
        #expect(preferences.chartConfigurations == [first])
    }
}
