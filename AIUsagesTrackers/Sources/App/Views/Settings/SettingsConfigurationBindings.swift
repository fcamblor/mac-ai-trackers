import SwiftUI
import AIUsagesTrackersLib

enum SettingsConfigurationBindings {
    @MainActor
    static func menuBarSegment(
        preferences: any AppPreferences,
        segmentID: UUID
    ) -> Binding<MenuBarSegmentConfig>? {
        let id = segmentID
        guard let current = preferences.menuBarSegments.first(where: { $0.id == id }) else { return nil }
        return Binding(
            get: {
                // Re-resolve by id: the index can shift between binding creation and
                // SwiftUI's deferred reads during a delete transaction.
                preferences.menuBarSegments.first(where: { $0.id == id }) ?? current
            },
            set: { newValue in
                guard let idx = preferences.menuBarSegments.firstIndex(where: { $0.id == id }) else { return }
                preferences.menuBarSegments[idx] = newValue
            }
        )
    }

    @MainActor
    static func chartConfiguration(
        preferences: any AppPreferences,
        configurationID: UUID
    ) -> Binding<ChartConfiguration>? {
        let id = configurationID
        guard let current = preferences.chartConfigurations.first(where: { $0.id == id }) else { return nil }
        return Binding(
            get: {
                // Re-resolve by id: the index can shift between binding creation and
                // SwiftUI's deferred reads during a delete transaction.
                preferences.chartConfigurations.first(where: { $0.id == id }) ?? current
            },
            set: { newValue in
                guard let idx = preferences.chartConfigurations.firstIndex(where: { $0.id == id }) else { return }
                preferences.chartConfigurations[idx] = newValue
            }
        )
    }
}
