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

@Suite("MenuBarChipResolver — Claude family merge")
struct ResolverClaudeFamilyTests {
    @Test("a Claude chip resolves a specific account from a claude-desktop entry")
    func specificResolvesAcrossFamily() {
        let result = firstResolved(
            chip: singleSegmentChip(vendor: .claude, account: .specific("me@example.com")),
            entries: [timeWindowEntry(vendor: .claudeDesktop, account: "me@example.com", isActive: true)]
        )
        #expect(result.rendered != nil)
        #expect(result.issue == nil)
    }

    @Test("currentlyActive prefers the active family member")
    func currentlyActivePrefersActiveMember() {
        let result = firstResolved(
            chip: singleSegmentChip(vendor: .claude, account: .currentlyActive),
            entries: [
                timeWindowEntry(vendor: .claude, account: "me@example.com", isActive: false, usagePercent: 10),
                timeWindowEntry(vendor: .claudeDesktop, account: "me@example.com", isActive: true, usagePercent: 77),
            ]
        )
        #expect(result.rendered?.text.contains("77%") == true)
    }
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
        #expect(seg?.tier != nil)
    }

    @Test("only percent")
    func percentOnly() {
        let seg = resolveWith(TimeWindowDisplay(
            showLetter: false, letter: "", showPercent: true, showReset: false
        ))
        #expect(seg?.text == "48%")
    }

    @Test("only reset")
    func resetOnly() {
        let seg = resolveWith(TimeWindowDisplay(
            showLetter: false, letter: "", showPercent: false, showReset: true
        ))
        #expect(seg?.text == "2h 13m")
    }

    @Test("remaining percent mode")
    func remainingPercent() {
        let seg = resolveWith(TimeWindowDisplay(
            showLetter: false, letter: "", showPercent: true,
            percentDisplayMode: .remaining, showReset: false
        ))
        #expect(seg?.text == "52%")
    }

    @Test("letter off hides the letter")
    func letterOff() {
        let seg = resolveWith(TimeWindowDisplay(
            showLetter: false, letter: "S",
            showPercent: true, showReset: true
        ))
        #expect(seg?.text == "48% 2h 13m")
    }

    @Test("percent off hides percent")
    func percentOff() {
        let seg = resolveWith(TimeWindowDisplay(
            showLetter: true, letter: "S",
            showPercent: false, showReset: true
        ))
        #expect(seg?.text == "S 2h 13m")
    }

    @Test("reset off hides remaining time")
    func resetOff() {
        let seg = resolveWith(TimeWindowDisplay(
            showLetter: true, letter: "S",
            showPercent: true, showReset: false
        ))
        #expect(seg?.text == "S 48%")
    }

    @Test("hideResetMinutesWhenOverOneDay collapses minutes past 24h")
    func resetHidesMinutesOverOneDay() {
        let display = TimeWindowDisplay(
            showLetter: true,
            letter: "W",
            showPercent: false,
            showReset: true,
            hideResetMinutesWhenOverOneDay: true
        )
        let chip = singleSegmentChip(
            metricName: "Weekly (all models)",
            display: .timeWindow(display)
        )
        let entry = timeWindowEntry(
            metricName: "Weekly (all models)",
            resetAt: "2026-04-20T05:30:00Z"
        )
        let now = ISO8601DateFormatter().date(from: "2026-04-17T00:00:00Z")!
        let result = firstResolved(chip: chip, entries: [entry], now: now)
        #expect(result.rendered?.text == "W 3d 6h")
    }

    @Test("all toggles off yields nil segment")
    func allOff() {
        // The decoder rejects this shape, but the resolver must still be
        // defensive: a TimeWindowDisplay built directly in Swift can bypass
        // the invariant, and we don't want the menu bar to surface an empty
        // pill in that case.
        let seg = resolveWith(TimeWindowDisplay(
            showLetter: false, letter: "S",
            showPercent: false, showReset: false
        ))
        #expect(seg == nil)
    }
}

@Suite("MenuBarChipResolver — unknown window (popover/menubar consistency)")
struct ResolverUnknownWindowTests {
    // When the reset is unknown, the percent has no interpretable window so
    // both percent and remaining degrade to "???". The renderer collapses the
    // pair into a single placeholder so the chip reads as "S ???" instead of
    // the awkward "S ??? ???". Popover and menubar must agree on that — these
    // tests guard the parity at the resolver boundary.

    private static func segment(
        resetAt: ISODate?,
        usagePercent: Int = 1,
        display: TimeWindowDisplay = TimeWindowDisplay(letter: "S")
    ) -> MenuBarSegment? {
        let entry = VendorUsageEntry(
            vendor: .codex,
            account: "user@openai.com",
            isActive: true,
            metrics: [.timeWindow(
                name: "Session (5h)",
                resetAt: resetAt,
                windowDuration: 300,
                usagePercent: UsagePercent(rawValue: usagePercent)
            )]
        )
        let chip = MenuBarChipConfig(
            vendor: .codex,
            segments: [
                MenuBarChipSegmentConfig(
                    account: .currentlyActive,
                    metricName: "Session (5h)",
                    display: .timeWindow(display)
                )
            ]
        )
        return firstResolved(chip: chip, entries: [entry]).rendered
    }

    @Test("nil resetAt → single ??? placeholder (not duplicated for percent + remaining)")
    func nilResetAtCollapsesToSinglePlaceholder() {
        let result = ResolverUnknownWindowTests.segment(resetAt: nil, usagePercent: 1)
        #expect(result?.text == "S ???")
        #expect(result?.tier == nil)
    }

    @Test("elapsed resetAt → single ??? placeholder")
    func elapsedResetAtCollapsesToSinglePlaceholder() {
        let elapsed = ISODate(rawValue: "2026-04-17T10:00:00Z")
        let result = ResolverUnknownWindowTests.segment(resetAt: elapsed, usagePercent: 42)
        #expect(result?.text == "S ???")
        #expect(result?.tier == nil)
    }

    @Test("unknown window with only percent shown → still renders single ???")
    func unknownWithOnlyPercentDisplayed() {
        let result = ResolverUnknownWindowTests.segment(
            resetAt: nil,
            usagePercent: 1,
            display: TimeWindowDisplay(letter: "S", showReset: false)
        )
        #expect(result?.text == "S ???")
    }

    @Test("unknown window with only reset shown → still renders single ???")
    func unknownWithOnlyResetDisplayed() {
        let result = ResolverUnknownWindowTests.segment(
            resetAt: nil,
            usagePercent: 1,
            display: TimeWindowDisplay(letter: "S", showPercent: false)
        )
        #expect(result?.text == "S ???")
    }

    @Test("known reset with 0% → percent stays visible (0% is meaningful when window is known)")
    func knownResetWithZeroPercentStaysVisible() {
        let active = ISODate(rawValue: "2026-04-17T15:00:00Z")
        let result = ResolverUnknownWindowTests.segment(resetAt: active, usagePercent: 0)
        #expect(result?.text == "S 0% 2h 13m")
    }

    @Test("in-progress resetAt → menubar renders the percent and remaining time")
    func inProgressResetAtRendersValues() {
        let active = ISODate(rawValue: "2026-04-17T15:00:00Z")
        let result = ResolverUnknownWindowTests.segment(resetAt: active, usagePercent: 48)
        #expect(result?.text == "S 48% 2h 13m")
    }
}

@Suite("MenuBarChipResolver — multi-vendor isolation")
struct ResolverMultiVendorTests {
    @Test("an entry from another vendor is not picked up by the chip's resolver")
    func ignoresEntriesFromOtherVendors() {
        let claudeChip = singleSegmentChip(vendor: .claude)
        let codexEntry = timeWindowEntry(vendor: .codex, isActive: true)
        let result = firstResolved(chip: claudeChip, entries: [codexEntry])
        #expect(result.issue == .noActiveAccount(vendor: .claude))
        #expect(result.rendered == nil)
    }

    @Test("chip resolves only against entries of its own vendor when both are present")
    func picksOwnVendorAmongMany() {
        let codexChip = singleSegmentChip(
            vendor: .codex,
            metricName: "Session (5h)",
            display: .timeWindow(TimeWindowDisplay(letter: "S"))
        )
        let claudeEntry = timeWindowEntry(vendor: .claude, isActive: true)
        let codexEntry = VendorUsageEntry(
            vendor: .codex,
            account: "user@openai.com",
            isActive: true,
            metrics: [.timeWindow(
                name: "Session (5h)",
                resetAt: ISODate(rawValue: "2026-04-17T15:00:00Z"),
                windowDuration: 300,
                usagePercent: UsagePercent(rawValue: 48)
            )]
        )
        let result = firstResolved(chip: codexChip, entries: [claudeEntry, codexEntry])
        #expect(result.rendered?.text == "S 48% 2h 13m")
        #expect(result.issue == nil)
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
        #expect(result.rendered?.tier == nil)
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
