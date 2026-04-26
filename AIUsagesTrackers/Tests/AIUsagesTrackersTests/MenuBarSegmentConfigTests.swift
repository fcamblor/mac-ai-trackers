import Foundation
import Testing
@testable import AIUsagesTrackersLib

@Suite("AccountSelection")
struct AccountSelectionTests {
    @Test("currentlyActive round-trips through Codable")
    func currentlyActiveRoundTrip() throws {
        let original = AccountSelection.currentlyActive
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(AccountSelection.self, from: data)
        #expect(decoded == original)
    }

    @Test("specific round-trips through Codable")
    func specificRoundTrip() throws {
        let original = AccountSelection.specific("user@example.com")
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(AccountSelection.self, from: data)
        #expect(decoded == original)
    }

    @Test("currentlyActive encodes with stable discriminator")
    func currentlyActiveStableEncoding() throws {
        let data = try JSONEncoder().encode(AccountSelection.currentlyActive)
        let json = String(data: data, encoding: .utf8) ?? ""
        #expect(json.contains("\"currently-active\""))
    }

    @Test("specific encodes with email field")
    func specificEncoding() throws {
        let data = try JSONEncoder().encode(AccountSelection.specific("alice@example.com"))
        let json = String(data: data, encoding: .utf8) ?? ""
        #expect(json.contains("alice@example.com"))
        #expect(json.contains("\"specific\""))
    }
}

@Suite("SegmentDisplay")
struct SegmentDisplayTests {
    @Test("timeWindow round-trips preserving all flags")
    func timeWindowRoundTrip() throws {
        let original = SegmentDisplay.timeWindow(TimeWindowDisplay(
            showDot: false,
            showLetter: true,
            letter: "X",
            showPercent: false,
            percentDisplayMode: .remaining,
            showReset: true,
            hideResetMinutesWhenOverOneDay: true
        ))
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(SegmentDisplay.self, from: data)
        #expect(decoded == original)
    }

    @Test("payAsYouGo round-trips without extra fields")
    func payAsYouGoRoundTrip() throws {
        let original = SegmentDisplay.payAsYouGo
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(SegmentDisplay.self, from: data)
        #expect(decoded == original)
    }

    @Test("TimeWindowDisplay default init enables all toggles")
    func timeWindowDefaults() {
        let display = TimeWindowDisplay()
        #expect(display.showDot)
        #expect(display.showLetter)
        #expect(display.showPercent)
        #expect(display.percentDisplayMode == .consumed)
        #expect(display.showReset)
        #expect(display.hideResetMinutesWhenOverOneDay)
        #expect(!display.showVendorIcon)
    }

    @Test("TimeWindowDisplay JSON without newer fields decodes to defaults")
    func newerFieldsMissingDefault() throws {
        let json = """
        {"showDot":true,"showLetter":true,"letter":"S","showPercent":true,"showReset":true}
        """
        let data = json.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(TimeWindowDisplay.self, from: data)
        #expect(decoded.percentDisplayMode == .consumed)
        #expect(decoded.hideResetMinutesWhenOverOneDay)
        #expect(!decoded.showVendorIcon)
    }

    @Test("TimeWindowDisplay with showVendorIcon true round-trips")
    func showVendorIconRoundTrip() throws {
        let original = TimeWindowDisplay(showVendorIcon: true)
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(TimeWindowDisplay.self, from: data)
        #expect(decoded.showVendorIcon == true)
    }

    @Test("TimeWindowDisplay with remaining percent and compact reset round-trips")
    func newFieldsRoundTrip() throws {
        let original = TimeWindowDisplay(
            percentDisplayMode: .remaining,
            hideResetMinutesWhenOverOneDay: true
        )
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(TimeWindowDisplay.self, from: data)
        #expect(decoded.percentDisplayMode == .remaining)
        #expect(decoded.hideResetMinutesWhenOverOneDay)
    }
}

@Suite("MenuBarSegmentConfig")
struct MenuBarSegmentConfigTests {
    @Test("round-trips through Codable")
    func roundTrip() throws {
        let original = MenuBarSegmentConfig(
            vendor: .claude,
            account: .currentlyActive,
            metricName: "Weekly (all models)",
            display: .timeWindow(TimeWindowDisplay(letter: "W"))
        )
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(MenuBarSegmentConfig.self, from: data)
        #expect(decoded == original)
    }

    @Test("id survives Codable round-trip")
    func idSurvivesRoundTrip() throws {
        let original = MenuBarSegmentConfig(
            vendor: .claude,
            account: .specific("a@b.com"),
            metricName: "Weekly (all models)",
            display: .payAsYouGo
        )
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(MenuBarSegmentConfig.self, from: data)
        #expect(decoded.id == original.id)
    }

    @Test("array of mixed segments round-trips")
    func arrayRoundTrip() throws {
        let segments: [MenuBarSegmentConfig] = [
            MenuBarSegmentConfig(
                vendor: .claude,
                account: .currentlyActive,
                metricName: "5h sessions (all models)",
                display: .timeWindow(TimeWindowDisplay(letter: "S"))
            ),
            MenuBarSegmentConfig(
                vendor: .claude,
                account: .specific("user@example.com"),
                metricName: "Monthly cost",
                display: .payAsYouGo
            ),
        ]
        let data = try JSONEncoder().encode(segments)
        let decoded = try JSONDecoder().decode([MenuBarSegmentConfig].self, from: data)
        #expect(decoded == segments)
    }
}

@Suite("MenuBarMetricLetter")
struct MenuBarMetricLetterTests {
    @Test("known 5h sessions maps to S")
    func fiveHourSessions() {
        #expect(MenuBarMetricLetter.defaultLetter(for: "5h sessions (all models)") == "S")
    }

    @Test("known Weekly maps to W")
    func weekly() {
        #expect(MenuBarMetricLetter.defaultLetter(for: "Weekly (all models)") == "W")
    }

    @Test("unknown metric falls back to first char uppercased")
    func unknownFallback() {
        #expect(MenuBarMetricLetter.defaultLetter(for: "opus 4.7") == "O")
    }

    @Test("empty name yields empty letter")
    func empty() {
        #expect(MenuBarMetricLetter.defaultLetter(for: "") == "")
    }
}
