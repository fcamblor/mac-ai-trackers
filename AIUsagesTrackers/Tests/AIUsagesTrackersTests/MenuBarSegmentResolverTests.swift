import Foundation
import Testing
@testable import AIUsagesTrackersLib

private let referenceDate: Date = ISO8601DateFormatter().date(from: "2026-04-17T12:47:00Z")!

private func timeWindowEntry(
    vendor: Vendor = .claude,
    account: AccountEmail = "user@example.com",
    isActive: Bool = true,
    metricName: String = "5h sessions (all models)",
    resetAt: String = "2026-04-17T15:00:00Z",
    usagePercent: Int = 48
) -> VendorUsageEntry {
    VendorUsageEntry(
        vendor: vendor,
        account: account,
        isActive: isActive,
        metrics: [.timeWindow(
            name: metricName,
            resetAt: ISODate(rawValue: resetAt),
            windowDuration: 300,
            usagePercent: UsagePercent(rawValue: usagePercent)
        )]
    )
}

private func payAsYouGoEntry(
    account: AccountEmail = "user@example.com",
    metricName: String = "Monthly cost",
    amount: Double = 12.50,
    currency: String = "USD"
) -> VendorUsageEntry {
    VendorUsageEntry(
        vendor: .claude,
        account: account,
        isActive: true,
        metrics: [.payAsYouGo(name: metricName, currentAmount: amount, currency: currency)]
    )
}

@Suite("MenuBarSegmentResolver — .currentlyActive")
struct ResolverCurrentlyActiveTests {
    @Test("renders when an active account exists")
    func rendersWhenActive() {
        let config = MenuBarSegmentConfig(
            vendor: .claude,
            account: .currentlyActive,
            metricName: "5h sessions (all models)",
            display: .timeWindow(TimeWindowDisplay(letter: "S"))
        )
        let result = MenuBarSegmentResolver.resolve(
            config: config,
            entries: [timeWindowEntry()],
            now: referenceDate
        )
        #expect(result.issue == nil)
        #expect(result.rendered?.text == "S 48% 2h 13m")
        #expect(result.rendered?.showDot == true)
    }

    @Test("renders single inactive account as implicitly active")
    func singleInactiveAccountIsImplicitlyActive() {
        let config = MenuBarSegmentConfig(
            vendor: .claude,
            account: .currentlyActive,
            metricName: "5h sessions (all models)",
            display: .timeWindow(TimeWindowDisplay(letter: "S"))
        )
        let result = MenuBarSegmentResolver.resolve(
            config: config,
            entries: [timeWindowEntry(isActive: false)],
            now: referenceDate
        )
        #expect(result.issue == nil)
        #expect(result.rendered?.text == "S 48% 2h 13m")
    }

    @Test("returns noActiveAccount when multiple accounts exist and none is active")
    func noActiveAccountWithMultipleEntries() {
        let config = MenuBarSegmentConfig(
            vendor: .claude,
            account: .currentlyActive,
            metricName: "5h sessions (all models)",
            display: .timeWindow(TimeWindowDisplay(letter: "S"))
        )
        let result = MenuBarSegmentResolver.resolve(
            config: config,
            entries: [
                timeWindowEntry(account: "a@example.com", isActive: false),
                timeWindowEntry(account: "b@example.com", isActive: false),
            ],
            now: referenceDate
        )
        #expect(result.rendered == nil)
        #expect(result.issue == .noActiveAccount(vendor: .claude))
    }

    @Test("ignores entries from other vendors")
    func otherVendor() {
        let otherVendor = Vendor(rawValue: "openai")
        let config = MenuBarSegmentConfig(
            vendor: .claude,
            account: .currentlyActive,
            metricName: "5h sessions (all models)",
            display: .timeWindow(TimeWindowDisplay(letter: "S"))
        )
        let entries = [timeWindowEntry(vendor: otherVendor, isActive: true)]
        let result = MenuBarSegmentResolver.resolve(config: config, entries: entries, now: referenceDate)
        #expect(result.issue == .noActiveAccount(vendor: .claude))
    }
}

@Suite("MenuBarSegmentResolver — .specific")
struct ResolverSpecificTests {
    @Test("renders when the specified account is present")
    func rendersWhenPresent() {
        let config = MenuBarSegmentConfig(
            vendor: .claude,
            account: .specific("user@example.com"),
            metricName: "5h sessions (all models)",
            display: .timeWindow(TimeWindowDisplay(letter: "S"))
        )
        let result = MenuBarSegmentResolver.resolve(
            config: config,
            entries: [timeWindowEntry(isActive: false)],
            now: referenceDate
        )
        #expect(result.issue == nil)
        #expect(result.rendered?.text == "S 48% 2h 13m")
    }

    @Test("returns accountNotFound when email is absent")
    func accountNotFound() {
        let missing: AccountEmail = "ghost@example.com"
        let config = MenuBarSegmentConfig(
            vendor: .claude,
            account: .specific(missing),
            metricName: "5h sessions (all models)",
            display: .timeWindow(TimeWindowDisplay(letter: "S"))
        )
        let result = MenuBarSegmentResolver.resolve(
            config: config,
            entries: [timeWindowEntry()],
            now: referenceDate
        )
        #expect(result.rendered == nil)
        #expect(result.issue == .accountNotFound(vendor: .claude, email: missing))
    }
}

@Suite("MenuBarSegmentResolver — metric lookup")
struct ResolverMetricLookupTests {
    @Test("returns metricNotFound when metric name is absent")
    func metricNotFound() {
        let config = MenuBarSegmentConfig(
            vendor: .claude,
            account: .currentlyActive,
            metricName: "Nonexistent",
            display: .timeWindow(TimeWindowDisplay(letter: "X"))
        )
        let result = MenuBarSegmentResolver.resolve(
            config: config,
            entries: [timeWindowEntry()],
            now: referenceDate
        )
        #expect(result.rendered == nil)
        #expect(result.issue == .metricNotFound(metricName: "Nonexistent"))
    }

    @Test("metricKindMismatch when timeWindow config targets payAsYouGo metric")
    func kindMismatchTWOverPAYG() {
        let config = MenuBarSegmentConfig(
            vendor: .claude,
            account: .currentlyActive,
            metricName: "Monthly cost",
            display: .timeWindow(TimeWindowDisplay(letter: "M"))
        )
        let result = MenuBarSegmentResolver.resolve(
            config: config,
            entries: [payAsYouGoEntry()],
            now: referenceDate
        )
        #expect(result.issue == .metricKindMismatch)
    }
}

@Suite("MenuBarSegmentResolver — timeWindow toggles")
struct ResolverTimeWindowTogglesTests {
    private func resolveWith(_ display: TimeWindowDisplay) -> MenuBarSegment? {
        let config = MenuBarSegmentConfig(
            vendor: .claude,
            account: .currentlyActive,
            metricName: "5h sessions (all models)",
            display: .timeWindow(display)
        )
        return MenuBarSegmentResolver.resolve(
            config: config,
            entries: [timeWindowEntry()],
            now: referenceDate
        ).rendered
    }

    @Test("all toggles on produces letter + percent + reset + dot")
    func allOn() {
        let segment = resolveWith(TimeWindowDisplay(
            showDot: true, showLetter: true, letter: "S",
            showPercent: true, showReset: true
        ))
        #expect(segment?.text == "S 48% 2h 13m")
        #expect(segment?.showDot == true)
        #expect(segment?.tier != nil)
    }

    @Test("percent off hides percent")
    func percentOff() {
        let segment = resolveWith(TimeWindowDisplay(
            showDot: true, showLetter: true, letter: "S",
            showPercent: false, showReset: true
        ))
        #expect(segment?.text == "S 2h 13m")
    }

    @Test("remaining percent mode shows allowance left")
    func remainingPercent() {
        let segment = resolveWith(TimeWindowDisplay(
            showDot: true, showLetter: true, letter: "S",
            showPercent: true, percentDisplayMode: .remaining, showReset: false
        ))
        #expect(segment?.text == "S 52%")
    }

    @Test("reset off hides remaining time")
    func resetOff() {
        let segment = resolveWith(TimeWindowDisplay(
            showDot: true, showLetter: true, letter: "S",
            showPercent: true, showReset: false
        ))
        #expect(segment?.text == "S 48%")
    }

    @Test("letter off hides the letter")
    func letterOff() {
        let segment = resolveWith(TimeWindowDisplay(
            showDot: true, showLetter: false, letter: "S",
            showPercent: true, showReset: true
        ))
        #expect(segment?.text == "48% 2h 13m")
    }

    @Test("dot off clears tier and showDot")
    func dotOff() {
        let segment = resolveWith(TimeWindowDisplay(
            showDot: false, showLetter: true, letter: "S",
            showPercent: true, showReset: true
        ))
        #expect(segment?.showDot == false)
        #expect(segment?.tier == nil)
    }

    @Test("reset can hide minutes when duration is over one day")
    func resetHidesMinutesOverOneDay() {
        let config = MenuBarSegmentConfig(
            vendor: .claude,
            account: .currentlyActive,
            metricName: "Weekly (all models)",
            display: .timeWindow(TimeWindowDisplay(
                showDot: false,
                showLetter: true,
                letter: "W",
                showPercent: false,
                showReset: true,
                hideResetMinutesWhenOverOneDay: true
            ))
        )
        let entry = timeWindowEntry(
            metricName: "Weekly (all models)",
            resetAt: "2026-04-20T05:30:00Z"
        )
        let now = ISO8601DateFormatter().date(from: "2026-04-17T00:00:00Z")!
        let result = MenuBarSegmentResolver.resolve(config: config, entries: [entry], now: now)
        #expect(result.rendered?.text == "W 3d 6h")
    }

    @Test("all toggles off yields nil segment")
    func allOff() {
        let segment = resolveWith(TimeWindowDisplay(
            showDot: false, showLetter: false, letter: "S",
            showPercent: false, showReset: false
        ))
        #expect(segment == nil)
    }
}

@Suite("MenuBarSegmentResolver — payAsYouGo")
struct ResolverPayAsYouGoTests {
    @Test("renders amount + currency without dot")
    func rendersAmountCurrency() {
        let config = MenuBarSegmentConfig(
            vendor: .claude,
            account: .currentlyActive,
            metricName: "Monthly cost",
            display: .payAsYouGo
        )
        let result = MenuBarSegmentResolver.resolve(
            config: config,
            entries: [payAsYouGoEntry(amount: 42.1, currency: "EUR")],
            now: referenceDate
        )
        #expect(result.rendered?.text == "42.10 EUR")
        #expect(result.rendered?.showDot == false)
        #expect(result.rendered?.tier == nil)
        #expect(result.rendered?.vendorIcon == nil)
    }
}

@Suite("MenuBarSegmentResolver — showVendorIcon")
struct ResolverVendorIconTests {
    private func resolveWith(_ display: TimeWindowDisplay) -> MenuBarSegment? {
        let config = MenuBarSegmentConfig(
            vendor: .claude,
            account: .currentlyActive,
            metricName: "5h sessions (all models)",
            display: .timeWindow(display)
        )
        return MenuBarSegmentResolver.resolve(
            config: config,
            entries: [timeWindowEntry()],
            now: referenceDate
        ).rendered
    }

    @Test("showVendorIcon false produces nil vendorIcon")
    func vendorIconOff() {
        let segment = resolveWith(TimeWindowDisplay(showVendorIcon: false))
        #expect(segment?.vendorIcon == nil)
    }

    @Test("showVendorIcon true populates vendorIcon with the config vendor")
    func vendorIconOn() {
        let segment = resolveWith(TimeWindowDisplay(showVendorIcon: true))
        #expect(segment?.vendorIcon == .claude)
    }

    @Test("payAsYouGo segment never carries a vendorIcon")
    func payAsYouGoHasNoVendorIcon() {
        let config = MenuBarSegmentConfig(
            vendor: .claude,
            account: .currentlyActive,
            metricName: "Monthly cost",
            display: .payAsYouGo
        )
        let result = MenuBarSegmentResolver.resolve(
            config: config,
            entries: [payAsYouGoEntry()],
            now: referenceDate
        )
        #expect(result.rendered?.vendorIcon == nil)
    }
}
