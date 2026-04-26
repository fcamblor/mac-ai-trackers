import Foundation

public enum UsageHistoryTimeWindow: String, CaseIterable, Identifiable, Sendable {
    case sixHours
    case twentyFourHours
    case sevenDays
    case thirtyDays
    case all

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .sixHours: "6h"
        case .twentyFourHours: "24h"
        case .sevenDays: "7d"
        case .thirtyDays: "30d"
        case .all: "All"
        }
    }

    public func startDate(relativeTo now: Date) -> Date? {
        guard let timeInterval else {
            return nil
        }
        return now.addingTimeInterval(-timeInterval)
    }

    public var timeInterval: TimeInterval? {
        switch self {
        case .sixHours:
            6 * 60 * 60
        case .twentyFourHours:
            24 * 60 * 60
        case .sevenDays:
            7 * 24 * 60 * 60
        case .thirtyDays:
            30 * 24 * 60 * 60
        case .all:
            nil
        }
    }
}

public struct UsageHistoryPoint: Equatable, Identifiable, Sendable {
    public let timestamp: Date
    public let vendor: Vendor
    public let account: AccountEmail
    public let metricName: String
    public let metricKind: MetricKind
    public let value: Double?
    public let unit: String

    public init(
        timestamp: Date,
        vendor: Vendor,
        account: AccountEmail,
        metricName: String,
        metricKind: MetricKind,
        value: Double?,
        unit: String
    ) {
        self.timestamp = timestamp
        self.vendor = vendor
        self.account = account
        self.metricName = metricName
        self.metricKind = metricKind
        self.value = value
        self.unit = unit
    }

    public var id: String {
        "\(seriesID)|\(timestamp.timeIntervalSince1970)"
    }

    public var seriesID: String {
        "\(vendor.rawValue)|\(account.rawValue)|\(metricName)|\(metricKind.rawValueForDisplay)|\(unit)"
    }

    public var seriesLabel: String {
        "\(vendor.rawValue) / \(account.rawValue) / \(metricName)"
    }
}

public struct UsageHistorySeriesSummary: Equatable, Identifiable, Sendable {
    public let id: String
    public let label: String
    public let metricName: String
    public let latestValue: Double
    public let unit: String
    public let pointCount: Int

    public init(id: String, label: String, metricName: String, latestValue: Double, unit: String, pointCount: Int) {
        self.id = id
        self.label = label
        self.metricName = metricName
        self.latestValue = latestValue
        self.unit = unit
        self.pointCount = pointCount
    }
}

public struct UsageHistorySnapshot: Equatable, Sendable {
    public static let empty = UsageHistorySnapshot(
        points: [],
        skippedLineCount: 0,
        hasDataBeforeWindow: false,
        hasDataAfterWindow: false
    )

    public let points: [UsageHistoryPoint]
    public let skippedLineCount: Int
    public let hasDataBeforeWindow: Bool
    public let hasDataAfterWindow: Bool

    public init(
        points: [UsageHistoryPoint],
        skippedLineCount: Int,
        hasDataBeforeWindow: Bool = false,
        hasDataAfterWindow: Bool = false
    ) {
        self.points = points
        self.skippedLineCount = skippedLineCount
        self.hasDataBeforeWindow = hasDataBeforeWindow
        self.hasDataAfterWindow = hasDataAfterWindow
    }

    public var seriesSummaries: [UsageHistorySeriesSummary] {
        let grouped = Dictionary(grouping: points, by: \.seriesID)
        return grouped.compactMap { seriesID, points in
            guard let latest = points
                .filter({ $0.value != nil })
                .max(by: { $0.timestamp < $1.timestamp }),
                let latestValue = latest.value else { return nil }
            return UsageHistorySeriesSummary(
                id: seriesID,
                label: latest.seriesLabel,
                metricName: latest.metricName,
                latestValue: latestValue,
                unit: latest.unit,
                pointCount: points.filter { $0.value != nil }.count
            )
        }
        .sorted { $0.label.localizedStandardCompare($1.label) == .orderedAscending }
    }
}

public actor UsageHistoryReader {
    public nonisolated let rootPath: String
    private let fileManager: FileManager
    private let logger: FileLogger

    public init(
        rootPath: String? = nil,
        fileManager: FileManager = .default,
        logger: FileLogger = Loggers.app
    ) {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        self.rootPath = rootPath ?? "\(home)/.cache/ai-usages-tracker/usage-history"
        self.fileManager = fileManager
        self.logger = logger
    }

    public func load(window: UsageHistoryTimeWindow, now: Date = Date()) async -> UsageHistorySnapshot {
        let startDate = window.startDate(relativeTo: now)
        var points: [UsageHistoryPoint] = []
        var skippedLineCount = 0
        var hasDataBeforeWindow = false
        var hasDataAfterWindow = false

        for url in jsonlFileURLs() {
            let data: Data
            do {
                data = try Data(contentsOf: url)
            } catch {
                logger.log(.warning, "UsageHistoryReader: cannot read \(url.path): \(error)")
                continue
            }

            let lines = data.split(separator: Self.newlineByte, omittingEmptySubsequences: true)
            for line in lines {
                do {
                    let tick = try JSONDecoder().decode(TickSnapshot.self, from: Data(line))
                    guard let timestamp = tick.timestamp.date else {
                        continue
                    }
                    if let startDate, timestamp < startDate {
                        hasDataBeforeWindow = true
                        continue
                    }
                    if timestamp > now {
                        hasDataAfterWindow = true
                        continue
                    }
                    points.append(contentsOf: Self.points(from: tick, timestamp: timestamp))
                } catch {
                    skippedLineCount += 1
                }
            }
        }

        points.sort {
            if $0.timestamp == $1.timestamp {
                return $0.seriesLabel.localizedStandardCompare($1.seriesLabel) == .orderedAscending
            }
            return $0.timestamp < $1.timestamp
        }
        return UsageHistorySnapshot(
            points: points,
            skippedLineCount: skippedLineCount,
            hasDataBeforeWindow: window == .all ? false : hasDataBeforeWindow,
            hasDataAfterWindow: window == .all ? false : hasDataAfterWindow
        )
    }

    private func jsonlFileURLs() -> [URL] {
        let rootURL = URL(fileURLWithPath: rootPath, isDirectory: true)
        guard let enumerator = fileManager.enumerator(
            at: rootURL,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        var urls: [URL] = []
        for case let url as URL in enumerator where url.pathExtension == "jsonl" {
            let values = try? url.resourceValues(forKeys: [.isRegularFileKey])
            if values?.isRegularFile != false {
                urls.append(url)
            }
        }
        return urls.sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
    }

    private static func points(from tick: TickSnapshot, timestamp: Date) -> [UsageHistoryPoint] {
        tick.accounts.flatMap { account in
            account.metrics.compactMap { metric in
                point(from: metric, account: account, timestamp: timestamp)
            }
        }
    }

    private static func point(
        from metric: MetricSnapshot,
        account: AccountSnapshot,
        timestamp: Date
    ) -> UsageHistoryPoint? {
        switch metric.kind {
        case .timeWindow:
            return UsageHistoryPoint(
                timestamp: timestamp,
                vendor: account.vendor,
                account: account.account,
                metricName: metric.name,
                metricKind: metric.kind,
                value: metric.usagePercent.map { Double($0.rawValue) },
                unit: "%"
            )
        case .payAsYouGo:
            return UsageHistoryPoint(
                timestamp: timestamp,
                vendor: account.vendor,
                account: account.account,
                metricName: metric.name,
                metricKind: metric.kind,
                value: metric.currentAmount,
                unit: metric.currency ?? ""
            )
        case .unknown:
            return nil
        }
    }

    private static let newlineByte: UInt8 = 0x0A
}

private extension MetricKind {
    var rawValueForDisplay: String {
        switch self {
        case .timeWindow: "time-window"
        case .payAsYouGo: "pay-as-you-go"
        case .unknown(let rawValue): rawValue
        }
    }
}
