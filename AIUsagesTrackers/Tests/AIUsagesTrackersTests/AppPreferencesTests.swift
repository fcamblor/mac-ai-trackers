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
        #expect(prefs.menuBarChips.isEmpty)
        #expect(prefs.menuBarChipsInitialized == false)
        #expect(prefs.menuBarChipBackground == .default)
        #expect(prefs.menuBarPacingColorCycleEnabled == false)
        #expect(prefs.chartConfigurations.isEmpty)
        #expect(prefs.chartConfigurationsInitialized == false)
    }

    @Test("menuBarChipBackground round-trips through UserDefaults")
    @MainActor
    func menuBarChipBackgroundRoundTrip() {
        let (defaults, name) = makeSuite()
        defer { cleanUp(suiteName: name) }

        let prefs = UserDefaultsAppPreferences(defaults: defaults)
        prefs.menuBarChipBackground = .slate
        #expect(prefs.menuBarChipBackground == .slate)

        let reader = UserDefaultsAppPreferences(defaults: defaults)
        #expect(reader.menuBarChipBackground == .slate)
    }

    @Test("menuBarPacingColorCycleEnabled round-trips")
    @MainActor
    func menuBarPacingColorCycleRoundTrip() {
        let (defaults, name) = makeSuite()
        defer { cleanUp(suiteName: name) }

        let prefs = UserDefaultsAppPreferences(defaults: defaults)
        prefs.menuBarPacingColorCycleEnabled = true
        #expect(prefs.menuBarPacingColorCycleEnabled == true)
    }

    @Test("menuBarChips round-trips through UserDefaults")
    @MainActor
    func menuBarChipsRoundTrip() {
        let (defaults, name) = makeSuite()
        defer { cleanUp(suiteName: name) }

        let prefs = UserDefaultsAppPreferences(defaults: defaults)
        let chips = [
            MenuBarChipConfig(
                vendor: .claude,
                segments: [
                    MenuBarChipSegmentConfig(
                        account: .currentlyActive,
                        metricName: "Weekly (all models)",
                        display: .timeWindow(TimeWindowDisplay(letter: "W"))
                    )
                ]
            ),
        ]
        prefs.menuBarChips = chips
        #expect(prefs.menuBarChips == chips)
    }

    @Test("menuBarChips persists across instances")
    @MainActor
    func menuBarChipsPersist() {
        let (defaults, name) = makeSuite()
        defer { cleanUp(suiteName: name) }

        let writer = UserDefaultsAppPreferences(defaults: defaults)
        let chip = MenuBarChipConfig(
            vendor: .claude,
            segments: [
                MenuBarChipSegmentConfig(
                    account: .specific("a@b.com"),
                    metricName: "Cost",
                    display: .payAsYouGo
                )
            ]
        )
        writer.menuBarChips = [chip]

        let reader = UserDefaultsAppPreferences(defaults: defaults)
        #expect(reader.menuBarChips == [chip])
    }

    @Test("menuBarChipsInitialized round-trips")
    @MainActor
    func menuBarChipsInitializedRoundTrip() {
        let (defaults, name) = makeSuite()
        defer { cleanUp(suiteName: name) }

        let prefs = UserDefaultsAppPreferences(defaults: defaults)
        prefs.menuBarChipsInitialized = true
        #expect(prefs.menuBarChipsInitialized == true)
    }

    @Test("corrupt menuBarChips JSON returns empty array")
    @MainActor
    func corruptMenuBarChips() {
        let (defaults, name) = makeSuite()
        defer { cleanUp(suiteName: name) }

        defaults.set(Data("not json".utf8), forKey: AppPreferenceKeys.menuBarChips.rawValue)
        let prefs = UserDefaultsAppPreferences(defaults: defaults)
        #expect(prefs.menuBarChips.isEmpty)
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
