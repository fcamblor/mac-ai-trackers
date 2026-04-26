import Foundation

public struct ResolvedChartSeries: Equatable, Identifiable, Sendable {
    public let id: String
    public let label: String
    public let points: [UsageHistoryPoint]
    public let style: ChartSeriesStyle?

    public init(
        id: String,
        label: String,
        points: [UsageHistoryPoint],
        style: ChartSeriesStyle?
    ) {
        self.id = id
        self.label = label
        self.points = points
        self.style = style
    }
}

public enum ChartSeriesResolver {
    public static func resolve(
        configuration: ChartConfiguration,
        points: [UsageHistoryPoint],
        currentEntries: [VendorUsageEntry]
    ) -> [ResolvedChartSeries] {
        switch configuration.selection {
        case .allAvailable:
            return allAvailableSeries(from: points)
        case .custom(let configs):
            return configs.map { config in
                customSeries(config: config, points: points, currentEntries: currentEntries)
            }
        }
    }

    private static func allAvailableSeries(from points: [UsageHistoryPoint]) -> [ResolvedChartSeries] {
        let grouped = Dictionary(grouping: points, by: \.seriesID)
        return grouped.compactMap { seriesID, seriesPoints in
            guard let latest = seriesPoints
                .filter({ $0.value != nil })
                .max(by: { $0.timestamp < $1.timestamp }) else { return nil }
            return ResolvedChartSeries(
                id: seriesID,
                label: latest.seriesLabel,
                points: seriesPoints.sorted(by: usageHistoryPointSort),
                style: nil
            )
        }
        .sorted { $0.label.localizedStandardCompare($1.label) == .orderedAscending }
    }

    private static func customSeries(
        config: ChartSeriesConfig,
        points: [UsageHistoryPoint],
        currentEntries: [VendorUsageEntry]
    ) -> ResolvedChartSeries {
        guard let account = resolveAccount(
            vendor: config.vendor,
            account: config.account,
            currentEntries: currentEntries
        ) else {
            let label = fallbackLabel(for: config)
            return ResolvedChartSeries(
                id: config.id.uuidString,
                label: effectiveLabel(for: config, defaultLabel: label),
                points: [],
                style: config.style
            )
        }

        let matching = points.filter { point in
            point.vendor == config.vendor
                && point.account == account
                && point.metricName == config.metricName
        }
        .sorted(by: usageHistoryPointSort)

        let defaultLabel = matching.last?.seriesLabel ?? "\(config.vendor.rawValue) / \(account.rawValue) / \(config.metricName)"
        return ResolvedChartSeries(
            id: config.id.uuidString,
            label: effectiveLabel(for: config, defaultLabel: defaultLabel),
            points: matching,
            style: config.style
        )
    }

    private static func resolveAccount(
        vendor: Vendor,
        account: AccountSelection,
        currentEntries: [VendorUsageEntry]
    ) -> AccountEmail? {
        switch account {
        case .currentlyActive:
            return currentEntries.first { $0.vendor == vendor && $0.isActive }?.account
        case .specific(let email):
            return email
        }
    }

    private static func fallbackLabel(for config: ChartSeriesConfig) -> String {
        switch config.account {
        case .currentlyActive:
            return "\(config.vendor.rawValue) / currently active / \(config.metricName)"
        case .specific(let email):
            return "\(config.vendor.rawValue) / \(email.rawValue) / \(config.metricName)"
        }
    }

    private static func effectiveLabel(for config: ChartSeriesConfig, defaultLabel: String) -> String {
        let customLabel = config.label.trimmingCharacters(in: .whitespacesAndNewlines)
        return customLabel.isEmpty ? defaultLabel : customLabel
    }

    private static func usageHistoryPointSort(_ lhs: UsageHistoryPoint, _ rhs: UsageHistoryPoint) -> Bool {
        if lhs.timestamp == rhs.timestamp {
            return lhs.seriesLabel.localizedStandardCompare(rhs.seriesLabel) == .orderedAscending
        }
        return lhs.timestamp < rhs.timestamp
    }
}
