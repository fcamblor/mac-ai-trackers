import Foundation

// MARK: - Resolution

public enum MenuBarSegmentIssue: Equatable, Sendable {
    /// `.currentlyActive` was selected but no account for the vendor is flagged active.
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

public struct ResolvedMenuBarSegment: Sendable {
    public let config: MenuBarSegmentConfig
    public let rendered: MenuBarSegment?
    public let issue: MenuBarSegmentIssue?

    public init(config: MenuBarSegmentConfig, rendered: MenuBarSegment?, issue: MenuBarSegmentIssue?) {
        self.config = config
        self.rendered = rendered
        self.issue = issue
    }
}

// MARK: - Resolver

/// Converts a `MenuBarSegmentConfig` + a snapshot of usage entries into either a
/// renderable `MenuBarSegment` or a structured issue that the Settings UI can
/// surface to the user.
public enum MenuBarSegmentResolver {

    public static func resolve(
        config: MenuBarSegmentConfig,
        entries: [VendorUsageEntry],
        now: Date
    ) -> ResolvedMenuBarSegment {
        let vendorEntries = entries.filter { $0.vendor == config.vendor }

        let entry: VendorUsageEntry?
        let resolveIssue: MenuBarSegmentIssue?
        switch config.account {
        case .currentlyActive:
            if let active = vendorEntries.first(where: { $0.isActive }) {
                entry = active
                resolveIssue = nil
            } else if vendorEntries.count == 1 {
                // No account is flagged active, but there is only one — treat it as implicitly active
                // so the user sees their data without having to wait for the monitor to sync.
                entry = vendorEntries[0]
                resolveIssue = nil
            } else {
                entry = nil
                resolveIssue = .noActiveAccount(vendor: config.vendor)
            }
        case .specific(let email):
            if let match = vendorEntries.first(where: { $0.account == email }) {
                entry = match
                resolveIssue = nil
            } else {
                entry = nil
                resolveIssue = .accountNotFound(vendor: config.vendor, email: email)
            }
        }

        guard let entry else {
            return ResolvedMenuBarSegment(config: config, rendered: nil, issue: resolveIssue)
        }

        guard let metric = entry.metrics.first(where: { metricName($0) == config.metricName }) else {
            return ResolvedMenuBarSegment(
                config: config,
                rendered: nil,
                issue: .metricNotFound(metricName: config.metricName)
            )
        }

        switch (metric, config.display) {
        case let (.timeWindow(_, resetAt, windowDuration, usagePercent), .timeWindow(display)):
            let segment = renderTimeWindow(
                display: display,
                vendor: config.vendor,
                resetAt: resetAt,
                windowDuration: windowDuration,
                usagePercent: usagePercent,
                now: now
            )
            return ResolvedMenuBarSegment(config: config, rendered: segment, issue: nil)

        case let (.payAsYouGo(_, currentAmount, currency), .payAsYouGo):
            let segment = renderPayAsYouGo(currentAmount: currentAmount, currency: currency)
            return ResolvedMenuBarSegment(config: config, rendered: segment, issue: nil)

        default:
            return ResolvedMenuBarSegment(config: config, rendered: nil, issue: .metricKindMismatch)
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
        vendor: Vendor,
        resetAt: ISODate?,
        windowDuration: DurationMinutes,
        usagePercent: UsagePercent,
        now: Date
    ) -> MenuBarSegment? {
        var parts: [String] = []
        if display.showLetter, !display.letter.isEmpty {
            parts.append(display.letter)
        }
        if display.showPercent {
            parts.append(formatUsagePercent(usagePercent, mode: display.percentDisplayMode))
        }
        if display.showReset {
            let remaining = resetAt.map {
                formatRemainingTime(
                    resetAt: $0,
                    now: now,
                    hideMinutesWhenOverOneDay: display.hideResetMinutesWhenOverOneDay
                )
            } ?? "???"
            parts.append(remaining)
        }
        let text = parts.joined(separator: " ")

        let tier: ConsumptionTier?
        if display.showDot {
            let theoretical = resetAt.map { theoreticalFraction(resetAt: $0, windowDuration: windowDuration, now: now) } ?? 0.0
            tier = consumptionRatio(actualPercent: usagePercent, theoreticalFraction: theoretical)
                .map { consumptionTier(ratio: $0) }
        } else {
            tier = nil
        }

        // If the user turned every visible element off, there's nothing to render
        if text.isEmpty, !display.showDot, !display.showVendorIcon {
            return nil
        }

        let vendorIcon: Vendor? = display.showVendorIcon ? vendor : nil
        return MenuBarSegment(text: text, tier: tier, showDot: display.showDot, vendorIcon: vendorIcon)
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
        return MenuBarSegment(text: "\(amount) \(currency)", tier: nil, showDot: false)
    }
}
