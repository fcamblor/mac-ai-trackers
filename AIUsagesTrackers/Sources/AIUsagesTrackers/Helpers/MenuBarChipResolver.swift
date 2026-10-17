import Foundation

// MARK: - Resolution outputs

public enum MenuBarSegmentIssue: Equatable, Sendable {
    /// `.currentlyActive` was selected but no account for the chip's vendor is flagged active.
    case noActiveAccount(vendor: Vendor)
    /// A specific account was selected but it's absent from the usages file.
    case accountNotFound(vendor: Vendor, email: AccountEmail)
    /// The target metric name is not present on the resolved account.
    case metricNotFound(metricName: String)
    /// The metric exists but its kind doesn't match the configured display variant
    /// (e.g. timeWindow display on a pay-as-you-go metric). Happens when the user
    /// changes the underlying metric kind externally.
    case metricKindMismatch
}

public struct ResolvedChipSegment: Sendable {
    public let config: MenuBarChipSegmentConfig
    public let rendered: MenuBarSegment?
    public let issue: MenuBarSegmentIssue?

    public init(
        config: MenuBarChipSegmentConfig,
        rendered: MenuBarSegment?,
        issue: MenuBarSegmentIssue?
    ) {
        self.config = config
        self.rendered = rendered
        self.issue = issue
    }
}

public struct ResolvedMenuBarChip: Sendable {
    public let chip: MenuBarChipConfig
    /// True when the chip's vendor currently has at least one active outage.
    /// Computed once for the chip (vendor-level) rather than re-checked for
    /// every segment.
    public let hasActiveOutage: Bool
    public let segments: [ResolvedChipSegment]

    public init(
        chip: MenuBarChipConfig,
        hasActiveOutage: Bool,
        segments: [ResolvedChipSegment]
    ) {
        self.chip = chip
        self.hasActiveOutage = hasActiveOutage
        self.segments = segments
    }

    /// The text rendered alongside the vendor icon when the chip opts into
    /// outage warnings and the vendor currently has at least one active
    /// outage. Empty warning text is treated as "no warning" to match the
    /// existing UI affordance where clearing the field disables the badge.
    public var outageWarningText: String? {
        guard chip.showOutageWarning, hasActiveOutage else { return nil }
        return chip.outageWarningText.isEmpty ? nil : chip.outageWarningText
    }
}

// MARK: - Resolver

/// Converts a `MenuBarChipConfig` + a snapshot of usage entries and outages
/// into the renderable structure used by the menu bar label, while preserving
/// per-segment issues so the Settings UI can surface them to the user.
public enum MenuBarChipResolver {

    public static func resolve(
        chip: MenuBarChipConfig,
        entries: [VendorUsageEntry],
        outagesByVendor: [Vendor: [Outage]],
        now: Date
    ) -> ResolvedMenuBarChip {
        // Outages are filed per vendor; match by family so a Claude chip picks
        // up Anthropic outages regardless of which Claude vendor stored them.
        let hasOutage = outagesByVendor.contains { vendor, outages in
            vendor.accountFamily == chip.vendor.accountFamily && !outages.isEmpty
        }
        let resolvedSegments = chip.segments.map { segmentConfig in
            resolveSegment(
                vendor: chip.vendor,
                segmentConfig: segmentConfig,
                entries: entries,
                now: now
            )
        }
        return ResolvedMenuBarChip(
            chip: chip,
            hasActiveOutage: hasOutage,
            segments: resolvedSegments
        )
    }

    private static func resolveSegment(
        vendor: Vendor,
        segmentConfig: MenuBarChipSegmentConfig,
        entries: [VendorUsageEntry],
        now: Date
    ) -> ResolvedChipSegment {
        // Match by account family so a chip scoped to Claude resolves across
        // both Claude CLI and Claude Desktop entries (they are one account).
        let vendorEntries = entries.filter { $0.vendor.accountFamily == vendor.accountFamily }

        let entry: VendorUsageEntry?
        let resolveIssue: MenuBarSegmentIssue?
        switch segmentConfig.account {
        case .currentlyActive:
            if let active = vendorEntries.filter(\.isActive).representativeEntry() {
                entry = active
                resolveIssue = nil
            } else if vendorEntries.count == 1 {
                // No account is flagged active, but there is only one — treat it as implicitly active
                // so the user sees their data without having to wait for the monitor to sync.
                entry = vendorEntries[0]
                resolveIssue = nil
            } else {
                entry = nil
                resolveIssue = .noActiveAccount(vendor: vendor)
            }
        case .specific(let email):
            // Same email may exist under several family vendors; pick the
            // representative (active → freshest → non-errored).
            if let match = vendorEntries.filter({ $0.account == email }).representativeEntry() {
                entry = match
                resolveIssue = nil
            } else {
                entry = nil
                resolveIssue = .accountNotFound(vendor: vendor, email: email)
            }
        }

        guard let entry else {
            return ResolvedChipSegment(config: segmentConfig, rendered: nil, issue: resolveIssue)
        }

        guard let metric = entry.metrics.first(where: { metricName($0) == segmentConfig.metricName }) else {
            return ResolvedChipSegment(
                config: segmentConfig,
                rendered: nil,
                issue: .metricNotFound(metricName: segmentConfig.metricName)
            )
        }

        switch (metric, segmentConfig.display) {
        case let (.timeWindow(_, resetAt, windowDuration, usagePercent), .timeWindow(display)):
            let segment = renderTimeWindow(
                display: display,
                resetAt: resetAt,
                windowDuration: windowDuration,
                usagePercent: usagePercent,
                now: now
            )
            return ResolvedChipSegment(config: segmentConfig, rendered: segment, issue: nil)

        case let (.payAsYouGo(_, currentAmount, currency), .payAsYouGo):
            let segment = renderPayAsYouGo(currentAmount: currentAmount, currency: currency)
            return ResolvedChipSegment(config: segmentConfig, rendered: segment, issue: nil)

        default:
            return ResolvedChipSegment(config: segmentConfig, rendered: nil, issue: .metricKindMismatch)
        }
    }

    private static func metricName(_ metric: UsageMetric) -> String? {
        switch metric {
        case .timeWindow(let name, _, _, _):   return name
        case .payAsYouGo(let name, _, _):      return name
        case .unknown:                         return nil
        }
    }

    // MARK: Rendering

    private static func renderTimeWindow(
        display: TimeWindowDisplay,
        resetAt: ISODate?,
        windowDuration: DurationMinutes,
        usagePercent: UsagePercent,
        now: Date
    ) -> MenuBarSegment? {
        // Single source of truth shared with TimeWindowMetricRow — see
        // TimeWindowVisualState. Do NOT recompute isUnknown / tier locally.
        let state = TimeWindowVisualState(
            resetAt: resetAt,
            windowDuration: windowDuration,
            usagePercent: usagePercent,
            now: now
        )

        var parts: [String] = []
        if display.showLetter, !display.letter.isEmpty {
            parts.append(display.letter)
        }
        if state.isUnknown {
            // Both percent and remaining would otherwise be "???" — collapse
            // them into a single placeholder when at least one is shown, to
            // avoid the awkward "S ??? ???" double placeholder.
            if display.showPercent || display.showReset {
                parts.append("???")
            }
        } else {
            if display.showPercent {
                parts.append(formatUsagePercent(usagePercent, mode: display.percentDisplayMode))
            }
            if display.showReset, let resetAt {
                parts.append(formatRemainingTime(
                    resetAt: resetAt,
                    now: now,
                    hideMinutesWhenOverOneDay: display.hideResetMinutesWhenOverOneDay
                ))
            }
        }
        let text = parts.joined(separator: " ")

        // The tier drives the pill background colour. It still reflects the
        // underlying usage state regardless of which textual toggles are on.
        let tier: ConsumptionTier? = state.tier

        // Display invariants guarantee at least one toggle is on, so `text`
        // shouldn't be empty under normal use — but a payload with all toggles
        // off would still surface as an empty pill, which is meaningless.
        if text.isEmpty {
            return nil
        }

        return MenuBarSegment(text: text, tier: tier)
    }

    private static func formatUsagePercent(_ usagePercent: UsagePercent, mode: UsagePercentDisplayMode) -> String {
        switch mode {
        case .consumed:
            return "\(usagePercent.rawValue)%"
        case .remaining:
            return "\(max(0, 100 - usagePercent.rawValue))%"
        }
    }

    private static func renderPayAsYouGo(currentAmount: Double, currency: String) -> MenuBarSegment {
        let amount = String(format: "%.2f", currentAmount)
        return MenuBarSegment(text: "\(amount) \(currency)", tier: nil)
    }
}
