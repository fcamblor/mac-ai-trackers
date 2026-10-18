import Foundation

/// Parses the `https://api.anthropic.com/api/oauth/usage` JSON payload into a
/// vendor-neutral list of `UsageMetric`. Shared by every connector that reads
/// this endpoint (the Claude TUI connector and the Claude Desktop
/// connector) so the window/breakdown mapping lives in exactly one place and
/// both vendors benefit from the same enrichment.
///
/// The parser is pure: it holds no credentials and performs no I/O. Unknown
/// top-level keys are ignored by design — the endpoint grows experimental
/// fields over time and only the windows documented in
/// `docs/vendors/claude.md` are consumed.
public struct ClaudeUsageResponseParser: Sendable {
    /// Claude Pro/Max rate-limit policy — durations are fixed by Anthropic and
    /// not returned by the API.
    public static let sessionWindowMinutes = DurationMinutes(rawValue: 300)
    public static let weeklyWindowMinutes = DurationMinutes(rawValue: 10080)

    public struct Snapshot: Sendable, Equatable {
        public let sessionPercent: Int?
        public let sessionResetAt: ISODate?
        public let weeklyPercent: Int?
        public let weeklyResetAt: ISODate?
        public let sonnetWeekly: ModelWeekly?
        public let opusWeekly: ModelWeekly?
        public let breakdownRows: [BreakdownRow]
        public let extraUsage: ExtraUsage?
    }

    public struct ModelWeekly: Sendable, Equatable {
        public let percent: Int
        public let resetAt: ISODate?
    }

    /// One row of `seven_day_breakdown.rows` — the share of the weekly
    /// consumption attributed to a product (Claude Code / Chats / Cowork /
    /// Other). This is a *share* of what was consumed, not utilization of an
    /// independent limit; see `docs/vendors/claude-desktop.md` metric semantics.
    public struct BreakdownRow: Sendable, Equatable {
        public let key: String
        public let displayName: String
        public let percent: Int
    }

    public struct ExtraUsage: Sendable, Equatable {
        public let amount: Double
        public let currency: String
    }

    public enum ParseError: Error, CustomStringConvertible {
        case notAnObject
        case noKnownWindow(receivedKeys: [String])

        public var description: String {
            switch self {
            case .notAnObject:
                "API response is not a JSON object"
            case let .noKnownWindow(keys):
                "API response does not match expected format — top-level keys: \(keys)"
            }
        }
    }

    public init() {}

    /// Parses the raw payload into a `Snapshot`. Throws `ParseError` only when
    /// the payload carries no recognizable window at all — a freshly
    /// provisioned account (`utilization: 0, resets_at: null`) is a valid,
    /// non-throwing result.
    public func parse(_ data: Data) throws -> Snapshot {
        let jsonObject = try JSONSerialization.jsonObject(with: data)
        guard let json = jsonObject as? [String: Any] else {
            throw ParseError.notAnObject
        }

        let session = Self.extractWindow(from: json, key: "five_hour")
        let weekly = Self.extractWindow(from: json, key: "seven_day")
        let sonnet = Self.extractWindow(from: json, key: "seven_day_sonnet")
        let opus = Self.extractWindow(from: json, key: "seven_day_opus")
        let breakdown = Self.extractBreakdown(from: json)
        let extraUsage = Self.extractExtraUsage(from: json)

        let hasFiveHour = json["five_hour"] is [String: Any]
        let hasSevenDay = json["seven_day"] is [String: Any]
        if !hasFiveHour, !hasSevenDay, extraUsage == nil {
            throw ParseError.noKnownWindow(receivedKeys: Array(json.keys))
        }

        return Snapshot(
            sessionPercent: session.map { Int($0.percent) },
            sessionResetAt: session.flatMap { $0.resetAt.map(Self.normalizeISO8601) },
            weeklyPercent: weekly.map { Int($0.percent) },
            weeklyResetAt: weekly.flatMap { $0.resetAt.map(Self.normalizeISO8601) },
            sonnetWeekly: sonnet.map { ModelWeekly(percent: $0.percent, resetAt: $0.resetAt.map(Self.normalizeISO8601)) },
            opusWeekly: opus.map { ModelWeekly(percent: $0.percent, resetAt: $0.resetAt.map(Self.normalizeISO8601)) },
            breakdownRows: breakdown,
            extraUsage: extraUsage
        )
    }

    /// Builds the ordered metric list from a snapshot. A window is emitted
    /// whenever its utilization is known, even if `resetAt` is null (fresh
    /// account) — the UI surfaces a null reset as "???" rather than dropping
    /// the row. Per-product breakdown rows are emitted only when the weekly
    /// window itself is present, sharing its reset date and window duration.
    public func metrics(from snapshot: Snapshot) -> [UsageMetric] {
        var metrics: [UsageMetric] = []
        if let percent = snapshot.sessionPercent {
            metrics.append(.timeWindow(
                name: "5h sessions (all models)",
                resetAt: snapshot.sessionResetAt,
                windowDuration: Self.sessionWindowMinutes,
                usagePercent: UsagePercent(rawValue: percent)
            ))
        }
        if let percent = snapshot.weeklyPercent {
            metrics.append(.timeWindow(
                name: "Weekly (all models)",
                resetAt: snapshot.weeklyResetAt,
                windowDuration: Self.weeklyWindowMinutes,
                usagePercent: UsagePercent(rawValue: percent)
            ))
        }
        let perModel: [(ModelWeekly?, String)] = [
            (snapshot.sonnetWeekly, "Weekly Sonnet"),
            (snapshot.opusWeekly, "Weekly Opus"),
        ]
        for (model, name) in perModel {
            if let model {
                metrics.append(.timeWindow(
                    name: name,
                    resetAt: model.resetAt,
                    windowDuration: Self.weeklyWindowMinutes,
                    usagePercent: UsagePercent(rawValue: model.percent)
                ))
            }
        }
        if snapshot.weeklyPercent != nil {
            for row in snapshot.breakdownRows {
                metrics.append(.timeWindow(
                    name: "Weekly share · \(row.displayName)",
                    resetAt: snapshot.weeklyResetAt,
                    windowDuration: Self.weeklyWindowMinutes,
                    usagePercent: UsagePercent(rawValue: row.percent)
                ))
            }
        }
        if let extraUsage = snapshot.extraUsage {
            metrics.append(.payAsYouGo(
                name: "Extra usage spent",
                currentAmount: extraUsage.amount,
                currency: extraUsage.currency
            ))
        }
        return metrics
    }

    /// Convenience: parse then build metrics in one call.
    public func parseMetrics(_ data: Data) throws -> [UsageMetric] {
        metrics(from: try parse(data))
    }

    // MARK: - Field extraction

    private static func extractWindow(from json: [String: Any], key: String) -> (percent: Int, resetAt: String?)? {
        guard let block = json[key] as? [String: Any],
              let util = block["utilization"] as? Double else {
            return nil
        }
        return (percent: Int(util.rounded()), resetAt: block["resets_at"] as? String)
    }

    private static func extractBreakdown(from json: [String: Any]) -> [BreakdownRow] {
        guard let block = json["seven_day_breakdown"] as? [String: Any],
              let rows = block["rows"] as? [[String: Any]] else {
            return []
        }
        return rows.compactMap { row in
            guard let key = row["key"] as? String,
                  let percent = row["percent"] as? Double else {
                return nil
            }
            let displayName = (row["display_name"] as? String) ?? key
            return BreakdownRow(key: key, displayName: displayName, percent: Int(percent.rounded()))
        }
    }

    private static func extractExtraUsage(from json: [String: Any]) -> ExtraUsage? {
        guard let block = json["extra_usage"] as? [String: Any],
              block["is_enabled"] as? Bool == true,
              let usedCredits = block["used_credits"] as? Double,
              usedCredits >= 0 else {
            return nil
        }
        let rawCurrency = (block["currency"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let currency = (rawCurrency?.isEmpty == false) ? rawCurrency!.uppercased() : "USD"
        return ExtraUsage(amount: usedCredits / 100, currency: currency)
    }

    /// Strips sub-second precision from API-provided ISO 8601 strings so
    /// downstream consumers can rely on the standard formatter without enabling
    /// fractional-seconds parsing. Returns the original string wrapped verbatim
    /// if it cannot be parsed.
    static func normalizeISO8601(_ raw: String) -> ISODate {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let plain = ISO8601DateFormatter()
        if let date = fractional.date(from: raw) ?? plain.date(from: raw) {
            return ISODate(rawValue: plain.string(from: date))
        }
        return ISODate(rawValue: raw)
    }
}
