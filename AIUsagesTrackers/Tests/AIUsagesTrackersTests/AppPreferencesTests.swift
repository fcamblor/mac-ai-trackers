import Foundation
import Testing
@testable import AIUsagesTrackersLib

@Suite("RefreshInterval")
struct RefreshIntervalTests {
    @Test("validated returns success for in-range value")
    func validatedInRange() {
        let result = RefreshInterval.validated(120)
        #expect(result == .success(RefreshInterval(clamping: 120)))
    }

    @Test("validated returns failure below minimum")
    func validatedBelowMin() {
        let result = RefreshInterval.validated(10)
        #expect(result == .failure(.belowMinimum(requested: 10, minimum: 30)))
    }

    @Test("validated returns failure above maximum")
    func validatedAboveMax() {
        let result = RefreshInterval.validated(3600)
        #expect(result == .failure(.aboveMaximum(requested: 3600, maximum: 1800)))
    }

    @Test("clamping init clamps below minimum to 30")
    func clampsBelowMin() {
        let interval = RefreshInterval(clamping: 5)
        #expect(interval.seconds == 30)
    }

    @Test("clamping init clamps above maximum to 1800")
    func clampsAboveMax() {
        let interval = RefreshInterval(clamping: 9999)
        #expect(interval.seconds == 1800)
    }

    @Test("clamping init preserves in-range value")
    func clampsInRange() {
        let interval = RefreshInterval(clamping: 300)
        #expect(interval.seconds == 300)
    }

    @Test("duration property returns correct Duration")
    func durationProperty() {
        let interval = RefreshInterval(clamping: 60)
        #expect(interval.duration == .seconds(60))
    }

    @Test("default is 180 seconds")
    func defaultValue() {
        #expect(RefreshInterval.default.seconds == 180)
    }

    @Test("Codable round-trip preserves value")
    func codableRoundTrip() throws {
        let original = RefreshInterval(clamping: 90)
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(RefreshInterval.self, from: data)
        #expect(decoded == original)
    }

    @Test("Codable decoding clamps out-of-range")
    func codableDecodingClamps() throws {
        let json = "5".data(using: .utf8)!
        let decoded = try JSONDecoder().decode(RefreshInterval.self, from: json)
        #expect(decoded.seconds == 30)
    }

    @Test("ExpressibleByIntegerLiteral works")
    func integerLiteral() {
        let interval: RefreshInterval = 60
        #expect(interval.seconds == 60)
    }

    @Test("Comparable ordering")
    func comparable() {
        let a = RefreshInterval(clamping: 30)
        let b = RefreshInterval(clamping: 60)
        #expect(a < b)
        #expect(!(b < a))
    }
}

@Suite("UserDefaultsAppPreferences")
struct UserDefaultsAppPreferencesTests {
    private func makeSuite() -> (UserDefaults, String) {
        let name = "ai-tracker-test-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        return (defaults, name)
    }

    private func cleanUp(suiteName: String) {
        UserDefaults.standard.removePersistentDomain(forName: suiteName)
    }

    @Test("defaults are returned when suite is empty")
    @MainActor
    func emptyDefaults() {
        let (defaults, name) = makeSuite()
        defer { cleanUp(suiteName: name) }

        let prefs = UserDefaultsAppPreferences(defaults: defaults)
        #expect(prefs.refreshInterval == .default)
        #expect(prefs.launchAtLogin == false)
        #expect(prefs.logLevel == .info)
        #expect(prefs.menuBarSegments.isEmpty)
        #expect(prefs.menuBarSegmentsInitialized == false)
        #expect(prefs.menuBarSeparator == " | ")
        #expect(prefs.chartConfigurations.isEmpty)
        #expect(prefs.chartConfigurationsInitialized == false)
    }

    @Test("menuBarSeparator round-trips through UserDefaults")
    @MainActor
    func menuBarSeparatorRoundTrip() {
        let (defaults, name) = makeSuite()
        defer { cleanUp(suiteName: name) }

        let prefs = UserDefaultsAppPreferences(defaults: defaults)
        prefs.menuBarSeparator = " · "
        #expect(prefs.menuBarSeparator == " · ")

        let reader = UserDefaultsAppPreferences(defaults: defaults)
        #expect(reader.menuBarSeparator == " · ")
    }

    @Test("menuBarSeparator can be set to empty string")
    @MainActor
    func menuBarSeparatorEmpty() {
        let (defaults, name) = makeSuite()
        defer { cleanUp(suiteName: name) }

        let prefs = UserDefaultsAppPreferences(defaults: defaults)
        prefs.menuBarSeparator = ""
        #expect(prefs.menuBarSeparator == "")
    }

    @Test("menuBarSegments round-trips through UserDefaults")
    @MainActor
    func menuBarSegmentsRoundTrip() {
        let (defaults, name) = makeSuite()
        defer { cleanUp(suiteName: name) }

        let prefs = UserDefaultsAppPreferences(defaults: defaults)
        let segments = [
            MenuBarSegmentConfig(
                vendor: .claude,
                account: .currentlyActive,
                metricName: "Weekly (all models)",
                display: .timeWindow(TimeWindowDisplay(letter: "W"))
            ),
        ]
        prefs.menuBarSegments = segments
        #expect(prefs.menuBarSegments == segments)
    }

    @Test("menuBarSegments persists across instances")
    @MainActor
    func menuBarSegmentsPersist() {
        let (defaults, name) = makeSuite()
        defer { cleanUp(suiteName: name) }

        let writer = UserDefaultsAppPreferences(defaults: defaults)
        let segment = MenuBarSegmentConfig(
            vendor: .claude,
            account: .specific("a@b.com"),
            metricName: "Cost",
            display: .payAsYouGo
        )
        writer.menuBarSegments = [segment]

        let reader = UserDefaultsAppPreferences(defaults: defaults)
        #expect(reader.menuBarSegments == [segment])
    }

    @Test("menuBarSegmentsInitialized round-trips")
    @MainActor
    func menuBarSegmentsInitializedRoundTrip() {
        let (defaults, name) = makeSuite()
        defer { cleanUp(suiteName: name) }

        let prefs = UserDefaultsAppPreferences(defaults: defaults)
        prefs.menuBarSegmentsInitialized = true
        #expect(prefs.menuBarSegmentsInitialized == true)
    }

    @Test("corrupt menuBarSegments JSON returns empty array")
    @MainActor
    func corruptMenuBarSegments() {
        let (defaults, name) = makeSuite()
        defer { cleanUp(suiteName: name) }

        defaults.set(Data("not json".utf8), forKey: AppPreferenceKeys.menuBarSegments.rawValue)
        let prefs = UserDefaultsAppPreferences(defaults: defaults)
        #expect(prefs.menuBarSegments.isEmpty)
    }

    @Test("chartConfigurations round-trips through UserDefaults")
    @MainActor
    func chartConfigurationsRoundTrip() {
        let (defaults, name) = makeSuite()
        defer { cleanUp(suiteName: name) }

        let prefs = UserDefaultsAppPreferences(defaults: defaults)
        let configurations = [
            ChartConfiguration(
                title: "Custom",
                selection: .custom([
                    ChartSeriesConfig(
                        vendor: .claude,
                        account: .specific("a@b.com"),
                        metricName: "Cost",
                        style: ChartSeriesStyle(color: .orange, lineStyle: .dashed)
                    ),
                ])
            ),
        ]

        prefs.chartConfigurations = configurations
        #expect(prefs.chartConfigurations == configurations)
    }

    @Test("chartConfigurations persists across instances")
    @MainActor
    func chartConfigurationsPersist() {
        let (defaults, name) = makeSuite()
        defer { cleanUp(suiteName: name) }

        let writer = UserDefaultsAppPreferences(defaults: defaults)
        let configuration = ChartConfiguration(title: "All", selection: .allAvailable)
        writer.chartConfigurations = [configuration]

        let reader = UserDefaultsAppPreferences(defaults: defaults)
        #expect(reader.chartConfigurations == [configuration])
    }

    @Test("chartConfigurationsInitialized round-trips")
    @MainActor
    func chartConfigurationsInitializedRoundTrip() {
        let (defaults, name) = makeSuite()
        defer { cleanUp(suiteName: name) }

        let prefs = UserDefaultsAppPreferences(defaults: defaults)
        prefs.chartConfigurationsInitialized = true
        #expect(prefs.chartConfigurationsInitialized == true)
    }

    @Test("corrupt chartConfigurations JSON returns empty array")
    @MainActor
    func corruptChartConfigurations() {
        let (defaults, name) = makeSuite()
        defer { cleanUp(suiteName: name) }

        defaults.set(Data("not json".utf8), forKey: AppPreferenceKeys.chartConfigurations.rawValue)
        let prefs = UserDefaultsAppPreferences(defaults: defaults)
        #expect(prefs.chartConfigurations.isEmpty)
    }

    @Test("refreshInterval round-trips through UserDefaults")
    @MainActor
    func refreshIntervalRoundTrip() {
        let (defaults, name) = makeSuite()
        defer { cleanUp(suiteName: name) }

        let prefs = UserDefaultsAppPreferences(defaults: defaults)
        prefs.refreshInterval = RefreshInterval(clamping: 60)
        #expect(prefs.refreshInterval.seconds == 60)

        // Verify the raw value stored in defaults
        let raw = defaults.integer(forKey: AppPreferenceKeys.refreshIntervalSeconds.rawValue)
        #expect(raw == 60)
    }

    @Test("launchAtLogin round-trips through UserDefaults")
    @MainActor
    func launchAtLoginRoundTrip() {
        let (defaults, name) = makeSuite()
        defer { cleanUp(suiteName: name) }

        let prefs = UserDefaultsAppPreferences(defaults: defaults)
        prefs.launchAtLogin = true
        #expect(prefs.launchAtLogin == true)
    }

    @Test("logLevel round-trips through UserDefaults")
    @MainActor
    func logLevelRoundTrip() {
        let (defaults, name) = makeSuite()
        defer { cleanUp(suiteName: name) }

        let prefs = UserDefaultsAppPreferences(defaults: defaults)
        prefs.logLevel = .debug
        #expect(prefs.logLevel == .debug)

        prefs.logLevel = .error
        #expect(prefs.logLevel == .error)
    }

    @Test("refreshInterval clamps out-of-range values written externally")
    @MainActor
    func refreshIntervalClamps() {
        let (defaults, name) = makeSuite()
        defer { cleanUp(suiteName: name) }

        // Simulate an external write of an out-of-range value
        defaults.set(5, forKey: AppPreferenceKeys.refreshIntervalSeconds.rawValue)
        let prefs = UserDefaultsAppPreferences(defaults: defaults)
        #expect(prefs.refreshInterval.seconds == 30)
    }
}

@Suite("InMemoryAppPreferences")
struct InMemoryAppPreferencesTests {
    @Test("stores and retrieves values")
    @MainActor
    func storeAndRetrieve() {
        let prefs = InMemoryAppPreferences(
            refreshInterval: RefreshInterval(clamping: 60),
            launchAtLogin: true,
            logLevel: .debug
        )
        #expect(prefs.refreshInterval.seconds == 60)
        #expect(prefs.launchAtLogin == true)
        #expect(prefs.logLevel == .debug)

        prefs.logLevel = .error
        #expect(prefs.logLevel == .error)
    }
}
