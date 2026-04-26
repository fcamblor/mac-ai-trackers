import Foundation

/// Seeds the history chart preferences once. Existing users without chart
/// preferences get the same default as fresh installs.
@MainActor
public enum ChartConfigurationsSeeder {
    public static func defaultConfigurations() -> [ChartConfiguration] {
        [
            ChartConfiguration(
                title: "All available metrics",
                selection: .allAvailable
            ),
        ]
    }

    public static func seedIfNeeded(preferences: any AppPreferences) {
        guard !preferences.chartConfigurationsInitialized else { return }
        if preferences.chartConfigurations.isEmpty {
            preferences.chartConfigurations = defaultConfigurations()
        }
        preferences.chartConfigurationsInitialized = true
    }
}
