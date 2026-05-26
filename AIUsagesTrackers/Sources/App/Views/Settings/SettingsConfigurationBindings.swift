import SwiftUI
import AIUsagesTrackersLib

enum SettingsConfigurationBindings {
    @MainActor
    static func menuBarChip(
        preferences: any AppPreferences,
        chipID: UUID
    ) -> Binding<MenuBarChipConfig>? {
        let id = chipID
        guard let current = preferences.menuBarChips.first(where: { $0.id == id }) else { return nil }
        return Binding(
            get: {
                preferences.menuBarChips.first(where: { $0.id == id }) ?? current
            },
            set: { newValue in
                guard let idx = preferences.menuBarChips.firstIndex(where: { $0.id == id }) else { return }
                preferences.menuBarChips[idx] = newValue
            }
        )
    }

    /// Binding that addresses a single sub-segment inside the chip identified
    /// by `chipID`. Re-resolves by id on every read so deletes and reorders
    /// inside the chip don't dangle the binding between SwiftUI's deferred
    /// read and write phases.
    @MainActor
    static func menuBarChipSegment(
        preferences: any AppPreferences,
        chipID: UUID,
        segmentID: UUID
    ) -> Binding<MenuBarChipSegmentConfig>? {
        let chipId = chipID
        let segId = segmentID
        guard let chipIdx = preferences.menuBarChips.firstIndex(where: { $0.id == chipId }),
              let current = preferences.menuBarChips[chipIdx].segments.first(where: { $0.id == segId }) else {
            return nil
        }
        return Binding(
            get: {
                guard let cIdx = preferences.menuBarChips.firstIndex(where: { $0.id == chipId }),
                      let seg = preferences.menuBarChips[cIdx].segments.first(where: { $0.id == segId }) else {
                    return current
                }
                return seg
            },
            set: { newValue in
                guard let cIdx = preferences.menuBarChips.firstIndex(where: { $0.id == chipId }) else { return }
                var chip = preferences.menuBarChips[cIdx]
                guard let sIdx = chip.segments.firstIndex(where: { $0.id == segId }) else { return }
                chip.segments[sIdx] = newValue
                preferences.menuBarChips[cIdx] = chip
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
                preferences.chartConfigurations.first(where: { $0.id == id }) ?? current
            },
            set: { newValue in
                guard let idx = preferences.chartConfigurations.firstIndex(where: { $0.id == id }) else { return }
                preferences.chartConfigurations[idx] = newValue
            }
        )
    }
}
