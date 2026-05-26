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

/// Builds a single-segment chip matching the legacy resolver tests' shape.
private func singleSegmentChip(
    vendor: Vendor = .claude,
    account: AccountSelection = .currentlyActive,
    metricName: String = "5h sessions (all models)",
    display: SegmentDisplay = .timeWindow(TimeWindowDisplay(letter: "S")),
    showVendorIcon: Bool = false
) -> MenuBarChipConfig {
    MenuBarChipConfig(
        vendor: vendor,
        showVendorIcon: showVendorIcon,
        segments: [
            MenuBarChipSegmentConfig(
                account: account,
                metricName: metricName,
                display: display
            )
        ]
    )
}

private func firstResolved(
    chip: MenuBarChipConfig,
    entries: [VendorUsageEntry],
    outagesByVendor: [Vendor: [Outage]] = [:],
    now: Date = referenceDate
) -> ResolvedChipSegment {
    MenuBarChipResolver.resolve(
        chip: chip,
        entries: entries,
        outagesByVendor: outagesByVendor,
        now: now
    ).segments.first!
}

@Suite("MenuBarChipResolver — .currentlyActive")
struct ResolverCurrentlyActiveTests {
    @Test("renders when an active account exists")
    func rendersWhenActive() {
        let result = firstResolved(
            chip: singleSegmentChip(),
            entries: [timeWindowEntry()]
        )
        #expect(result.rendered?.text == "S 48% 2h 13m")
    }

    @Test("renders single inactive account as implicitly active")
    func singleInactiveAccountIsImplicitlyActive() {
        let result = firstResolved(
            chip: singleSegmentChip(),
            entries: [timeWindowEntry(isActive: false)]
        )
        #expect(result.rendered != nil)
        #expect(result.issue == nil)
    }

    @Test("returns noActiveAccount when multiple accounts exist and none is active")
    func noActiveAccountWithMultipleEntries() {
        let result = firstResolved(
            chip: singleSegmentChip(),
            entries: [
                timeWindowEntry(account: "a@example.com", isActive: false),
                timeWindowEntry(account: "b@example.com", isActive: false),
            ]
        )
        #expect(result.rendered == nil)
        #expect(result.issue == .noActiveAccount(vendor: .claude))
    }

    @Test("no entry for the configured vendor → noActiveAccount")
    func otherVendor() {
        let otherVendor = Vendor(rawValue: "openai")
        let entries = [timeWindowEntry(vendor: otherVendor, isActive: true)]
        let result = firstResolved(chip: singleSegmentChip(), entries: entries)
        #expect(result.issue == .noActiveAccount(vendor: .claude))
    }
}

@Suite("MenuBarChipResolver — .specific")
struct ResolverSpecificTests {
    @Test("renders when the specified account is present")
    func rendersWhenPresent() {
        let result = firstResolved(
            chip: singleSegmentChip(account: .specific("user@example.com")),
            entries: [timeWindowEntry(isActive: false)]
        )
        #expect(result.rendered != nil)
    }

    @Test("returns accountNotFound when the email is absent")
    func accountNotFound() {
        let missing: AccountEmail = "ghost@example.com"
        let result = firstResolved(
            chip: singleSegmentChip(account: .specific(missing)),
            entries: [timeWindowEntry()]
        )
        #expect(result.rendered == nil)
        #expect(result.issue == .accountNotFound(vendor: .claude, email: missing))
    }
}

@Suite("MenuBarChipResolver — metric lookup")
struct ResolverMetricTests {
    @Test("returns metricNotFound when metric name is absent")
    func metricNotFound() {
        let result = firstResolved(
            chip: singleSegmentChip(metricName: "Nonexistent",
                                    display: .timeWindow(TimeWindowDisplay(letter: "X"))),
            entries: [timeWindowEntry()]
        )
        #expect(result.rendered == nil)
        #expect(result.issue == .metricNotFound(metricName: "Nonexistent"))
    }

    @Test("metricKindMismatch when timeWindow config targets payAsYouGo metric")
    func kindMismatchTWOverPAYG() {
        let result = firstResolved(
            chip: singleSegmentChip(metricName: "Monthly cost",
                                    display: .timeWindow(TimeWindowDisplay(letter: "M"))),
            entries: [payAsYouGoEntry()]
        )
        #expect(result.issue == .metricKindMismatch)
    }
}

@Suite("MenuBarChipResolver — timeWindow toggles")
struct ResolverTimeWindowTogglesTests {
    private func resolveWith(_ display: TimeWindowDisplay) -> MenuBarSegment? {
        firstResolved(
            chip: singleSegmentChip(display: .timeWindow(display)),
            entries: [timeWindowEntry()]
        ).rendered
    }

    @Test("all toggles default → letter + percent + remaining")
    func allDefault() {
        let seg = resolveWith(TimeWindowDisplay(letter: "S"))
        #expect(seg?.text == "S 48% 2h 13m")
    }

    @Test("only percent")
    func percentOnly() {
        let seg = resolveWith(TimeWindowDisplay(
            showDot: false, showLetter: false, letter: "", showPercent: true, showReset: false
        ))
        #expect(seg?.text == "48%")
    }

    @Test("only reset")
    func resetOnly() {
        let seg = resolveWith(TimeWindowDisplay(
            showDot: false, showLetter: false, letter: "", showPercent: false, showReset: true
        ))
        #expect(seg?.text == "2h 13m")
    }

    @Test("remaining percent mode")
    func remainingPercent() {
        let seg = resolveWith(TimeWindowDisplay(
            showDot: false, showLetter: false, letter: "", showPercent: true,
            percentDisplayMode: .remaining, showReset: false
        ))
        #expect(seg?.text == "52%")
    }
}

@Suite("MenuBarChipResolver — payAsYouGo")
struct ResolverPayAsYouGoTests {
    @Test("renders amount + currency without dot")
    func rendersAmountCurrency() {
        let result = firstResolved(
            chip: singleSegmentChip(metricName: "Monthly cost", display: .payAsYouGo),
            entries: [payAsYouGoEntry(amount: 42.1, currency: "EUR")]
        )
        #expect(result.rendered?.text == "42.10 EUR")
        #expect(result.rendered?.showDot == false)
    }
}

@Suite("MenuBarChipResolver — outage warning")
struct ResolverOutageTests {
    @Test("hasActiveOutage true when vendor has outages and chip opts in")
    func vendorOutageOptIn() {
        let chip = MenuBarChipConfig(
            vendor: .claude,
            showOutageWarning: true,
            outageWarningText: "🚨",
            segments: [
                MenuBarChipSegmentConfig(
                    account: .currentlyActive,
                    metricName: "5h sessions (all models)",
                    display: .timeWindow(TimeWindowDisplay(letter: "S"))
                )
            ]
        )
        let outages: [Vendor: [Outage]] = [
            .claude: [Outage(
                vendor: .claude,
                errorMessage: "Investigating",
                severity: .major,
                since: ISODate(rawValue: "2026-04-17T10:00:00Z")
            )]
        ]
        let resolution = MenuBarChipResolver.resolve(
            chip: chip,
            entries: [timeWindowEntry()],
            outagesByVendor: outages,
            now: referenceDate
        )
        #expect(resolution.hasActiveOutage == true)
        #expect(resolution.outageWarningText == "🚨")
    }

    @Test("outageWarningText nil when chip opts out, even with active outage")
    func optedOut() {
        let chip = MenuBarChipConfig(
            vendor: .claude,
            showOutageWarning: false,
            segments: [
                MenuBarChipSegmentConfig(
                    account: .currentlyActive,
                    metricName: "5h sessions (all models)",
                    display: .timeWindow(TimeWindowDisplay(letter: "S"))
                )
            ]
        )
        let outages: [Vendor: [Outage]] = [
            .claude: [Outage(
                vendor: .claude,
                errorMessage: "Investigating",
                severity: .major,
                since: ISODate(rawValue: "2026-04-17T10:00:00Z")
            )]
        ]
        let resolution = MenuBarChipResolver.resolve(
            chip: chip,
            entries: [timeWindowEntry()],
            outagesByVendor: outages,
            now: referenceDate
        )
        #expect(resolution.hasActiveOutage == true)
        #expect(resolution.outageWarningText == nil)
    }
}
