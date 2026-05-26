import Foundation
import Testing
@testable import AIUsagesTrackers
@testable import AIUsagesTrackersLib

@MainActor
@Suite("Settings configuration bindings")
struct SettingsConfigurationBindingsTests {
    @Test("menu bar chip binding read survives target deletion")
    func menuBarChipBindingSurvivesTargetDeletion() {
        let first = MenuBarChipConfig(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000101")!,
            vendor: .claude,
            segments: [
                MenuBarChipSegmentConfig(
                    account: .currentlyActive,
                    metricName: "5h sessions (all models)",
                    display: .timeWindow(TimeWindowDisplay(letter: "S"))
                )
            ]
        )
        let target = MenuBarChipConfig(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000102")!,
            vendor: .claude,
            segments: [
                MenuBarChipSegmentConfig(
                    account: .currentlyActive,
                    metricName: "Weekly (all models)",
                    display: .timeWindow(TimeWindowDisplay(letter: "W"))
                )
            ]
        )
        let preferences = InMemoryAppPreferences(menuBarChips: [first, target])

        let binding = SettingsConfigurationBindings.menuBarChip(
            preferences: preferences,
            chipID: target.id
        )
        #expect(binding != nil)
        guard let binding else { return }

        preferences.menuBarChips.removeAll { $0.id == target.id }

        #expect(binding.wrappedValue == target)
        var edited = binding.wrappedValue
        edited.showVendorIcon = true
        binding.wrappedValue = edited
        #expect(preferences.menuBarChips == [first])
    }

    @Test("chip segment binding mutates the right slot")
    func chipSegmentBindingMutatesParent() {
        let segmentID = UUID(uuidString: "00000000-0000-0000-0000-000000000301")!
        let chip = MenuBarChipConfig(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000201")!,
            vendor: .claude,
            segments: [
                MenuBarChipSegmentConfig(
                    id: segmentID,
                    account: .currentlyActive,
                    metricName: "Original",
                    display: .timeWindow(TimeWindowDisplay(letter: "O"))
                )
            ]
        )
        let preferences = InMemoryAppPreferences(menuBarChips: [chip])

        let binding = SettingsConfigurationBindings.menuBarChipSegment(
            preferences: preferences,
            chipID: chip.id,
            segmentID: segmentID
        )
        #expect(binding != nil)
        guard let binding else { return }

        var edited = binding.wrappedValue
        edited.metricName = "Edited"
        binding.wrappedValue = edited

        #expect(preferences.menuBarChips.first?.segments.first?.metricName == "Edited")
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
