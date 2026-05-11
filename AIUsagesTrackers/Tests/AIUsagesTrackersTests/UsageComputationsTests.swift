import Foundation
import Testing
@testable import AIUsagesTrackersLib

// MARK: - Helpers

private func date(_ iso: String) -> Date {
    ISO8601DateFormatter().date(from: iso)!
}

// MARK: - formatRemainingTime

@Suite("formatRemainingTime")
struct FormatRemainingTimeTests {

    @Test("returns '--' for unparseable ISODate")
    func invalidDate() {
        let result = formatRemainingTime(resetAt: ISODate(rawValue: "not-a-date"), now: Date())
        #expect(result == "--")
    }

    @Test("returns '0m' when reset is in the past")
    func pastDate() {
        let now = date("2026-04-17T15:00:00Z")
        let result = formatRemainingTime(resetAt: ISODate(rawValue: "2026-04-17T14:00:00Z"), now: now)
        #expect(result == "0m")
    }

    @Test("returns '0m' when reset is exactly now")
    func exactlyNow() {
        let now = date("2026-04-17T15:00:00Z")
        let result = formatRemainingTime(resetAt: ISODate(rawValue: "2026-04-17T15:00:00Z"), now: now)
        #expect(result == "0m")
    }

    @Test("formats minutes only")
    func minutesOnly() {
        let now = date("2026-04-17T14:55:00Z")
        let result = formatRemainingTime(resetAt: ISODate(rawValue: "2026-04-17T15:00:00Z"), now: now)
        #expect(result == "5m")
    }

    @Test("formats hours and minutes")
    func hoursAndMinutes() {
        let now = date("2026-04-17T12:47:00Z")
        let result = formatRemainingTime(resetAt: ISODate(rawValue: "2026-04-17T15:00:00Z"), now: now)
        #expect(result == "2h 13m")
    }

    @Test("formats days, hours, and minutes")
    func daysHoursMinutes() {
        let now = date("2026-04-17T00:00:00Z")
        let result = formatRemainingTime(resetAt: ISODate(rawValue: "2026-04-20T05:30:00Z"), now: now)
        #expect(result == "3d 5h 30m")
    }

    @Test("can hide minutes when duration is over one day")
    func hidesMinutesOverOneDay() {
        let now = date("2026-04-17T00:00:00Z")
        let result = formatRemainingTime(
            resetAt: ISODate(rawValue: "2026-04-20T05:30:00Z"),
            now: now,
            hideMinutesWhenOverOneDay: true
        )
        #expect(result == "3d 6h")
    }

    @Test("hiding minutes rounds to the nearest hour when duration is over one day")
    func hidingMinutesRoundsOverOneDay() {
        let now = date("2026-04-17T00:00:00Z")
        let result = formatRemainingTime(
            resetAt: ISODate(rawValue: "2026-04-18T22:53:00Z"),
            now: now,
            hideMinutesWhenOverOneDay: true
        )
        #expect(result == "1d 23h")
    }

    @Test("formats exactly 1 day")
    func exactlyOneDay() {
        let now = date("2026-04-17T00:00:00Z")
        let result = formatRemainingTime(resetAt: ISODate(rawValue: "2026-04-18T00:00:00Z"), now: now)
        #expect(result == "1d")
    }
}

// MARK: - theoreticalFraction

@Suite("theoreticalFraction")
struct TheoreticalFractionTests {

    @Test("returns 0 for unparseable ISODate")
    func invalidDate() {
        let result = theoreticalFraction(
            resetAt: ISODate(rawValue: "bad"),
            windowDuration: DurationMinutes(rawValue: 300),
            now: Date()
        )
        #expect(result == 0)
    }

    @Test("returns 0 for zero window duration")
    func zeroDuration() {
        let result = theoreticalFraction(
            resetAt: ISODate(rawValue: "2026-04-17T15:00:00Z"),
            windowDuration: DurationMinutes(rawValue: 0),
            now: date("2026-04-17T14:00:00Z")
        )
        #expect(result == 0)
    }

    @Test("returns 0.5 at midpoint of window")
    func midpoint() {
        // Window: 300 min = 5h. Reset at 15:00 → start at 10:00. Now at 12:30 → 2.5h elapsed = 0.5
        let result = theoreticalFraction(
            resetAt: ISODate(rawValue: "2026-04-17T15:00:00Z"),
            windowDuration: DurationMinutes(rawValue: 300),
            now: date("2026-04-17T12:30:00Z")
        )
        #expect(abs(result - 0.5) < 0.001)
    }

    @Test("clamps to 1.0 when reset is in the past")
    func pastReset() {
        let result = theoreticalFraction(
            resetAt: ISODate(rawValue: "2026-04-17T10:00:00Z"),
            windowDuration: DurationMinutes(rawValue: 300),
            now: date("2026-04-17T15:00:00Z")
        )
        #expect(result == 1.0)
    }

    @Test("clamps to 0.0 before window starts")
    func beforeWindow() {
        // Window: 60 min. Reset at 15:00 → start at 14:00. Now at 13:00 → before start
        let result = theoreticalFraction(
            resetAt: ISODate(rawValue: "2026-04-17T15:00:00Z"),
            windowDuration: DurationMinutes(rawValue: 60),
            now: date("2026-04-17T13:00:00Z")
        )
        #expect(result == 0.0)
    }
}

// MARK: - formatResetDate

@Suite("formatResetDate")
struct FormatResetDateTests {

    // Fixed UTC reference: 2026-04-18T10:00:00Z
    private static let now = Date(timeIntervalSince1970: 1_776_513_600)

    @Test("returns '--' for unparseable ISODate")
    func invalidDate() {
        let result = formatResetDate(ISODate(rawValue: "bad"), now: Self.now)
        #expect(result == "--")
    }

    @Test("shows '@ HH:mm' when reset is today")
    func today() {
        // Same UTC day as now: 2026-04-18T15:00:00Z
        let result = formatResetDate(ISODate(rawValue: "2026-04-18T15:00:00Z"), now: Self.now)
        #expect(result.hasPrefix("@ "))
        #expect(!result.contains("Apr"))
        #expect(!result.contains("Tomorrow"))
    }

    @Test("shows 'Tomorrow @ HH:mm' when reset is the next calendar day")
    func tomorrow() {
        // Next UTC day: 2026-04-19T08:00:00Z
        let result = formatResetDate(ISODate(rawValue: "2026-04-19T08:00:00Z"), now: Self.now)
        #expect(result.hasPrefix("Tomorrow @ "))
        #expect(!result.contains("Apr"))
    }

    @Test("shows full date when reset is two or more days away")
    func laterDate() {
        // Two days later: 2026-04-20T08:00:00Z
        let result = formatResetDate(ISODate(rawValue: "2026-04-20T08:00:00Z"), now: Self.now)
        #expect(result != "--")
        #expect(!result.hasPrefix("tomorrow"))
        #expect(!result.contains("today"))
    }
}

// MARK: - sortedForDisplay

@Suite("sortedForDisplay")
struct SortedForDisplayTests {

    private func entry(vendor: String, account: String, isActive: Bool = false) -> VendorUsageEntry {
        VendorUsageEntry(
            vendor: Vendor(rawValue: vendor),
            account: AccountEmail(rawValue: account),
            isActive: isActive
        )
    }

    @Test("empty array returns empty")
    func emptyArray() {
        let result: [VendorUsageEntry] = [].sortedForDisplay()
        #expect(result.isEmpty)
    }

    @Test("single entry returns itself")
    func singleEntry() {
        let entries = [entry(vendor: "claude", account: "a@b.com")]
        let result = entries.sortedForDisplay()
        #expect(result.count == 1)
        #expect(result[0].vendor.rawValue == "claude")
    }

    @Test("sorts by vendor name alphabetically")
    func sortsByVendor() {
        let entries = [
            entry(vendor: "openai", account: "x@y.com"),
            entry(vendor: "claude", account: "a@b.com"),
        ]
        let result = entries.sortedForDisplay()
        #expect(result[0].vendor.rawValue == "claude")
        #expect(result[1].vendor.rawValue == "openai")
    }

    @Test("active entries come first within same vendor")
    func activeFirst() {
        let entries = [
            entry(vendor: "claude", account: "inactive@b.com", isActive: false),
            entry(vendor: "claude", account: "active@b.com", isActive: true),
        ]
        let result = entries.sortedForDisplay()
        #expect(result[0].isActive == true)
        #expect(result[1].isActive == false)
    }

    @Test("sorts by account alphabetically within same vendor and activity")
    func sortsByAccount() {
        let entries = [
            entry(vendor: "claude", account: "z@b.com", isActive: true),
            entry(vendor: "claude", account: "a@b.com", isActive: true),
        ]
        let result = entries.sortedForDisplay()
        #expect(result[0].account.rawValue == "a@b.com")
        #expect(result[1].account.rawValue == "z@b.com")
    }

    @Test("full three-level sort")
    func threeLevelSort() {
        let entries = [
            entry(vendor: "openai", account: "x@y.com", isActive: true),
            entry(vendor: "claude", account: "z@b.com", isActive: false),
            entry(vendor: "claude", account: "a@b.com", isActive: true),
            entry(vendor: "claude", account: "m@b.com", isActive: true),
        ]
        let result = entries.sortedForDisplay()
        // Claude active first (a, m), then claude inactive (z), then openai
        #expect(result[0].account.rawValue == "a@b.com")
        #expect(result[1].account.rawValue == "m@b.com")
        #expect(result[2].account.rawValue == "z@b.com")
        #expect(result[3].vendor.rawValue == "openai")
    }
}

// MARK: - vendorsWithMultipleAccounts

@Suite("vendorsWithMultipleAccounts")
struct VendorsWithMultipleAccountsTests {

    private func entry(vendor: String, account: String) -> VendorUsageEntry {
        VendorUsageEntry(vendor: Vendor(rawValue: vendor), account: AccountEmail(rawValue: account))
    }

    @Test("empty array returns empty set")
    func emptyArray() {
        let result: Set<Vendor> = [].vendorsWithMultipleAccounts()
        #expect(result.isEmpty)
    }

    @Test("single entry returns empty set")
    func singleEntry() {
        let result = [entry(vendor: "claude", account: "a@b.com")].vendorsWithMultipleAccounts()
        #expect(result.isEmpty)
    }

    @Test("two entries same vendor returns that vendor")
    func twoSameVendor() {
        let entries = [
            entry(vendor: "claude", account: "a@b.com"),
            entry(vendor: "claude", account: "c@d.com"),
        ]
        let result = entries.vendorsWithMultipleAccounts()
        #expect(result == [Vendor(rawValue: "claude")])
    }

    @Test("two entries different vendors returns empty set")
    func twoDifferentVendors() {
        let entries = [
            entry(vendor: "claude", account: "a@b.com"),
            entry(vendor: "openai", account: "c@d.com"),
        ]
        let result = entries.vendorsWithMultipleAccounts()
        #expect(result.isEmpty)
    }
}

// MARK: - excluding(ignoredAccounts:)

@Suite("excluding(ignoredAccounts:)")
struct ExcludingIgnoredAccountsTests {

    private func entry(vendor: String, account: String, isActive: Bool = false) -> VendorUsageEntry {
        VendorUsageEntry(
            vendor: Vendor(rawValue: vendor),
            account: AccountEmail(rawValue: account),
            isActive: isActive
        )
    }

    @Test("empty ignored list returns all entries")
    func emptyIgnoredList() {
        let entries = [
            entry(vendor: "claude", account: "a@b.com"),
            entry(vendor: "codex", account: "c@d.com"),
        ]
        let result = entries.excluding(ignoredAccounts: [])
        #expect(result.count == 2)
    }

    @Test("matching entry is removed")
    func matchingEntryRemoved() {
        let entries = [
            entry(vendor: "claude", account: "a@b.com"),
            entry(vendor: "claude", account: "z@b.com"),
        ]
        let ignored = [IgnoredAccount(vendor: .claude, account: "a@b.com")]
        let result = entries.excluding(ignoredAccounts: ignored)
        #expect(result.count == 1)
        #expect(result[0].account.rawValue == "z@b.com")
    }

    @Test("unknown ignored account has no effect")
    func unknownIgnoredAccountNoEffect() {
        let entries = [entry(vendor: "claude", account: "a@b.com")]
        let ignored = [IgnoredAccount(vendor: .claude, account: "other@b.com")]
        let result = entries.excluding(ignoredAccounts: ignored)
        #expect(result.count == 1)
    }

    @Test("all accounts of a vendor ignored returns empty for that vendor")
    func allVendorAccountsIgnored() {
        let entries = [
            entry(vendor: "claude", account: "a@b.com"),
            entry(vendor: "claude", account: "z@b.com"),
            entry(vendor: "codex", account: "c@d.com"),
        ]
        let ignored = [
            IgnoredAccount(vendor: .claude, account: "a@b.com"),
            IgnoredAccount(vendor: .claude, account: "z@b.com"),
        ]
        let result = entries.excluding(ignoredAccounts: ignored)
        #expect(result.count == 1)
        #expect(result[0].vendor == .codex)
    }

    @Test("vendor mismatch does not filter account")
    func vendorMismatchNoFilter() {
        let entries = [entry(vendor: "claude", account: "a@b.com")]
        let ignored = [IgnoredAccount(vendor: .codex, account: "a@b.com")]
        let result = entries.excluding(ignoredAccounts: ignored)
        #expect(result.count == 1)
    }
}

// MARK: - GaugeBar clamping (testing the logic extracted as free function pattern)

@Suite("GaugeBar clamping logic")
struct GaugeBarClampTests {

    // Mirrors GaugeBar.clamp — tests the clamping contract
    private func clamp(_ value: Double) -> Double {
        min(max(value, 0), 1)
    }

    @Test("negative values clamp to 0")
    func negativeClamps() {
        #expect(clamp(-0.5) == 0)
        #expect(clamp(-100) == 0)
    }

    @Test("values above 1 clamp to 1")
    func aboveOneClamps() {
        #expect(clamp(1.5) == 1)
        #expect(clamp(100) == 1)
    }

    @Test("values in range pass through")
    func inRange() {
        #expect(clamp(0) == 0)
        #expect(clamp(0.5) == 0.5)
        #expect(clamp(1) == 1)
    }

    @Test("NaN propagates through clamp")
    func nanPropagates() {
        // NaN comparisons return false, so min/max propagate NaN — upstream must prevent NaN inputs
        let result = clamp(Double.nan)
        #expect(result.isNaN)
    }
}

// MARK: - TimeWindowVisualState

@Suite("TimeWindowVisualState — single source of truth for popover and menubar")
struct TimeWindowVisualStateTests {
    // This struct is the ONE place where the "is this window unknown" rule
    // lives. Both TimeWindowMetricRow (popover) and MenuBarSegmentResolver
    // (menubar) instantiate it and read its flag — any divergence between
    // the two views would have to start by breaking the contract verified
    // here. Keep these tests strict.
    //
    // Semantic invariant: a percent is intrinsically tied to its window
    // ("X% of the last 5 hours"). When the reset is unknown, the percent
    // loses its denominator and is no longer interpretable — actualFraction
    // collapses to 0 and callers must render the percent text as "???"
    // alongside the remaining time. Both numbers degrade together.

    private static let now: Date = ISO8601DateFormatter().date(from: "2026-04-17T12:47:00Z")!

    @Test("nil resetAt → isUnknown, actualFraction collapses to 0, tier nil")
    func nilResetAt() {
        let state = TimeWindowVisualState(
            resetAt: nil,
            windowDuration: DurationMinutes(rawValue: 300),
            usagePercent: UsagePercent(rawValue: 42),
            now: Self.now
        )
        #expect(state.isUnknown == true)
        #expect(state.actualFraction == 0, "Percent without a known window has no denominator → render as ???")
        #expect(state.elapsedFraction == 0)
        #expect(state.tier == nil)
    }

    @Test("unparseable resetAt → isUnknown")
    func unparseableResetAt() {
        let state = TimeWindowVisualState(
            resetAt: ISODate(rawValue: "not-a-date"),
            windowDuration: DurationMinutes(rawValue: 300),
            usagePercent: UsagePercent(rawValue: 42),
            now: Self.now
        )
        #expect(state.isUnknown == true)
        #expect(state.actualFraction == 0)
        #expect(state.tier == nil)
    }

    @Test("elapsed resetAt (now > resetDate) → isUnknown")
    func elapsedResetAt() {
        let state = TimeWindowVisualState(
            resetAt: ISODate(rawValue: "2026-04-17T10:00:00Z"),
            windowDuration: DurationMinutes(rawValue: 300),
            usagePercent: UsagePercent(rawValue: 99),
            now: Self.now
        )
        #expect(state.isUnknown == true)
        #expect(state.actualFraction == 0)
        #expect(state.elapsedFraction == 0)
        #expect(state.tier == nil)
    }

    @Test("resetAt exactly now → NOT isUnknown (boundary included)")
    func resetAtExactlyNow() {
        let state = TimeWindowVisualState(
            resetAt: ISODate(rawValue: "2026-04-17T12:47:00Z"),
            windowDuration: DurationMinutes(rawValue: 300),
            usagePercent: UsagePercent(rawValue: 50),
            now: Self.now
        )
        #expect(state.isUnknown == false)
        #expect(state.actualFraction == 0.5)
    }

    @Test("in-progress resetAt → not isUnknown, fractions populated, tier computed")
    func inProgressResetAt() {
        // Window of 300 min ending at 15:00 → started at 10:00.
        // At 12:47, elapsed = 2h47 / 5h = 167/300 ≈ 0.5567.
        let state = TimeWindowVisualState(
            resetAt: ISODate(rawValue: "2026-04-17T15:00:00Z"),
            windowDuration: DurationMinutes(rawValue: 300),
            usagePercent: UsagePercent(rawValue: 48),
            now: Self.now
        )
        #expect(state.isUnknown == false)
        #expect(state.actualFraction == 0.48)
        #expect(state.elapsedFraction > 0.55 && state.elapsedFraction < 0.56)
        #expect(state.tier != nil)
    }

    @Test("0% with known reset → not isUnknown, 0% is meaningful and renders verbatim")
    func zeroPercentWithKnownResetStaysVisible() {
        // User scenario: weekly window legitimately at 0% with a known reset
        // a few days away. The 0% is real information and must be displayed
        // as 0% — NOT collapsed into ??? — because we know what window the
        // 0% refers to.
        let state = TimeWindowVisualState(
            resetAt: ISODate(rawValue: "2026-04-22T12:00:00Z"),
            windowDuration: DurationMinutes(rawValue: 10080),
            usagePercent: UsagePercent(rawValue: 0),
            now: Self.now
        )
        #expect(state.isUnknown == false)
        #expect(state.actualFraction == 0)
    }
}
