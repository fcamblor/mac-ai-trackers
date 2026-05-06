import Foundation
import os

public actor CopilotConnector: UsageConnector {
    nonisolated public let vendor: Vendor = .copilot

    private let auth: CopilotAuthProviding
    private let logger: FileLogger
    private let session: URLSession

    // Thread-safe login cache readable from nonisolated resolveActiveAccount()
    // without blocking the cooperative thread pool.
    private let _cachedLogin = OSAllocatedUnfairLock<AccountEmail?>(initialState: nil)
    private var lastKnownMetrics: [UsageMetric] = []

    /// Copilot premium-request quotas reset on a monthly cadence; the API exposes
    /// only an absolute reset date, so we synthesize a 30-day window for the UI's
    /// progress rendering — matching openusage's default.
    private static let monthlyWindowMinutes = DurationMinutes(rawValue: 30 * 24 * 60)

    private static let apiURL = URL(string: "https://api.github.com/copilot_internal/user")! // known-valid literal

    public init(
        auth: CopilotAuthProviding = CopilotAuth(),
        logger: FileLogger = Loggers.copilot,
        session: URLSession = .shared
    ) {
        self.auth = auth
        self.logger = logger
        self.session = session
    }

    // MARK: - UsageConnector

    nonisolated public func resolveActiveAccount() -> AccountEmail? {
        _cachedLogin.withLock { $0 }
    }

    /// Clears the cached login so the next `fetchUsages()` call resolves a fresh
    /// identity from auth. Called by the active-account monitor on `gh auth switch`.
    public func invalidateLoginCache() {
        _cachedLogin.withLock { $0 = nil }
        logger.log(.info, "Copilot login cache invalidated")
    }

    public func fetchUsages() async throws -> [VendorUsageEntry] {
        let credentials: CopilotCredentials
        do {
            credentials = try await auth.load()
        } catch {
            logger.log(.error, "Copilot credentials load failed: \(error)")
            return errorEntries(type: "token_error")
        }

        // Cache the login eagerly so offline error responses can still attribute
        // the entry to the right account.
        _cachedLogin.withLock { $0 = credentials.activeLogin }
        logger.log(.info, "Fetching Copilot usages for login=\(credentials.activeLogin) (token from \(credentials.tokenSource.rawValue))")

        var request = URLRequest(url: Self.apiURL)
        request.setValue("token \(credentials.accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(CopilotConstants.editorVersion, forHTTPHeaderField: "Editor-Version")
        request.setValue(CopilotConstants.editorPluginVersion, forHTTPHeaderField: "Editor-Plugin-Version")
        request.setValue(CopilotConstants.userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue(CopilotConstants.apiVersion, forHTTPHeaderField: "X-Github-Api-Version")
        request.timeoutInterval = CopilotConstants.requestTimeoutSeconds

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            logger.log(.error, "Copilot API request failed: \(error)")
            return errorEntries(type: "api_error", login: credentials.activeLogin)
        }

        let httpResponse = response as? HTTPURLResponse
        let httpCode = httpResponse?.statusCode ?? -1
        logger.log(.info, "Copilot API response: HTTP \(httpCode)")

        if httpCode == 401 || httpCode == 403 {
            logger.log(.warning, "Copilot API returned HTTP \(httpCode) — token expired/revoked or missing Copilot entitlement")
            return errorEntries(type: "token_expired", login: credentials.activeLogin)
        }

        if httpCode == 429 {
            let body = String(data: data, encoding: .utf8) ?? "<non-UTF8 body, \(data.count) bytes>"
            logger.log(.warning, "Copilot API rate-limited (HTTP 429): \(body)")
            return errorEntries(
                type: "http_429",
                login: credentials.activeLogin,
                isActive: true,
                preservedMetrics: lastKnownMetrics
            )
        }

        guard httpCode == 200 else {
            logger.log(.error, "Copilot API returned HTTP \(httpCode)")
            return errorEntries(type: "http_\(httpCode)", login: credentials.activeLogin)
        }

        logger.log(.debug, "Copilot API payload: \(Self.maskedPayload(data))")

        do {
            let metrics = try parseAPIResponse(data)
            lastKnownMetrics = metrics
            logger.log(.info, "Copilot fetched \(metrics.count) metric(s) for login=\(credentials.activeLogin)")
            return [VendorUsageEntry(
                vendor: vendor,
                account: credentials.activeLogin,
                isActive: true,
                lastAcquiredOn: ISODate(date: Date()),
                lastError: nil,
                metrics: metrics
            )]
        } catch {
            logger.log(.error, "Copilot response parse failed: \(error)")
            logger.log(.warning, "Copilot failed payload dump: \(Self.maskedPayload(data))")
            return errorEntries(type: "parse_error", login: credentials.activeLogin)
        }
    }

    // MARK: - Response parsing

    private func parseAPIResponse(_ data: Data) throws -> [UsageMetric] {
        let jsonObject = try JSONSerialization.jsonObject(with: data)
        guard let json = jsonObject as? [String: Any] else {
            throw CopilotConnectorError.unexpectedAPIFormat(receivedKeys: [])
        }

        var metrics: [UsageMetric] = []

        // Paid tier: `quota_snapshots` carries percent-remaining for each pool,
        // sharing a single `quota_reset_date`. `unlimited:true` means the user
        // is on a plan with no cap on that pool — surface no metric (the bar
        // would be misleading).
        if let snapshots = json["quota_snapshots"] as? [String: Any] {
            let resetAt = isoDate(from: json["quota_reset_date"])
            if let line = makeSnapshotMetric(name: "Premium", snapshot: snapshots["premium_interactions"], resetAt: resetAt) {
                metrics.append(line)
            }
            if let line = makeSnapshotMetric(name: "Chat", snapshot: snapshots["chat"], resetAt: resetAt) {
                metrics.append(line)
            }
        }

        // Free tier: absolute counters with a separate reset date.
        if let limited = json["limited_user_quotas"] as? [String: Any],
           let monthly = json["monthly_quotas"] as? [String: Any] {
            let resetAt = isoDate(from: json["limited_user_reset_date"])
            if let line = makeLimitedMetric(name: "Chat", remaining: limited["chat"], total: monthly["chat"], resetAt: resetAt) {
                metrics.append(line)
            }
            if let line = makeLimitedMetric(name: "Completions", remaining: limited["completions"], total: monthly["completions"], resetAt: resetAt) {
                metrics.append(line)
            }
        }

        if metrics.isEmpty {
            logger.log(.warning, "No known usage block in Copilot payload — top-level keys: \(Array(json.keys))")
            throw CopilotConnectorError.unexpectedAPIFormat(receivedKeys: Array(json.keys))
        }

        return metrics
    }

    private func makeSnapshotMetric(name: String, snapshot: Any?, resetAt: ISODate?) -> UsageMetric? {
        guard let dict = snapshot as? [String: Any] else { return nil }
        // `unlimited:true` is NOT a reason to skip: paid plans expose pools like
        // `premium_interactions` with `unlimited:true` (soft monthly allowance,
        // overage billed separately) where `percent_remaining` is still the
        // meaningful signal — matching openusage's behavior. Only skip when the
        // signal itself is missing or non-numeric.
        guard let percentRemaining = numericValue(dict["percent_remaining"]) else { return nil }
        let used = max(0.0, min(100.0, 100.0 - percentRemaining))
        return .timeWindow(
            name: name,
            resetAt: resetAt,
            windowDuration: Self.monthlyWindowMinutes,
            usagePercent: UsagePercent(rawValue: Int(used.rounded()))
        )
    }

    private func makeLimitedMetric(name: String, remaining: Any?, total: Any?, resetAt: ISODate?) -> UsageMetric? {
        guard let remainingValue = numericValue(remaining),
              let totalValue = numericValue(total),
              totalValue > 0 else { return nil }
        let used = max(0.0, totalValue - remainingValue)
        let percent = min(100.0, (used / totalValue) * 100.0)
        return .timeWindow(
            name: name,
            resetAt: resetAt,
            windowDuration: Self.monthlyWindowMinutes,
            usagePercent: UsagePercent(rawValue: Int(percent.rounded()))
        )
    }

    private func numericValue(_ value: Any?) -> Double? {
        if let double = value as? Double { return double }
        if let int = value as? Int { return Double(int) }
        if let nsnum = value as? NSNumber { return nsnum.doubleValue }
        return nil
    }

    private func isoDate(from raw: Any?) -> ISODate? {
        guard let raw = raw as? String, !raw.isEmpty else { return nil }
        // GitHub's `quota_reset_date` / `limited_user_reset_date` are calendar
        // dates (`yyyy-MM-dd`), not full ISO 8601 datetimes. Promote them to
        // UTC midnight so downstream code (which assumes a parseable datetime)
        // gets a well-formed value instead of silently treating it as missing.
        if let parsed = ISODate.parsingFlexibleDate(raw) { return parsed }
        logger.log(.warning, "Copilot reset date is not a parseable ISO 8601 value: '\(raw)' — dropping")
        return nil
    }

    // MARK: - Payload masking

    private static let sensitiveKeyPatterns = ["token", "key", "secret", "password", "email", "credential"]

    static func maskedPayload(_ data: Data) -> String {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return "<non-JSON, \(data.count) bytes>"
        }
        let masked = maskSensitiveFields(json)
        guard let out = try? JSONSerialization.data(withJSONObject: masked, options: [.sortedKeys]),
              let str = String(data: out, encoding: .utf8) else {
            return "<serialization failed>"
        }
        return str
    }

    static func maskSensitiveFields(_ dict: [String: Any]) -> [String: Any] {
        var result: [String: Any] = [:]
        for (key, value) in dict {
            let lower = key.lowercased()
            if sensitiveKeyPatterns.contains(where: { lower.contains($0) }) {
                result[key] = "***"
            } else if let nested = value as? [String: Any] {
                result[key] = maskSensitiveFields(nested)
            } else if let array = value as? [[String: Any]] {
                result[key] = array.map { maskSensitiveFields($0) }
            } else {
                result[key] = value
            }
        }
        return result
    }

    // MARK: - Error helpers

    private func errorEntries(
        type: String,
        login: AccountEmail? = nil,
        isActive: Bool = false,
        preservedMetrics: [UsageMetric] = []
    ) -> [VendorUsageEntry] {
        let resolved: AccountEmail? = login ?? _cachedLogin.withLock { $0 }
        guard let account = resolved else {
            logger.log(.warning, "Copilot identity_unresolved during \(type) — no usage entry written")
            return []
        }
        return [VendorUsageEntry(
            vendor: vendor,
            account: account,
            isActive: isActive,
            lastAcquiredOn: nil,
            lastError: UsageError(timestamp: ISODate(date: Date()), type: type),
            metrics: preservedMetrics
        )]
    }
}

public enum CopilotConnectorError: Error, CustomStringConvertible {
    case unexpectedAPIFormat(receivedKeys: [String])

    public var description: String {
        switch self {
        case let .unexpectedAPIFormat(keys):
            "Copilot API response does not match expected format — top-level keys: \(keys)"
        }
    }
}
