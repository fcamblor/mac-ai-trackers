import Foundation
import os

public actor CodexConnector: UsageConnector {
    nonisolated public let vendor: Vendor = .codex

    private enum IdentitySource: String {
        case responseBody = "response_body"
        case credentials = "credentials"
        case cache = "cache"
    }

    private let auth: CodexAuthProviding
    private let logger: FileLogger
    private let session: URLSession

    // Thread-safe email cache readable from nonisolated resolveActiveAccount()
    // without blocking the cooperative thread pool.
    private let _cachedEmail = OSAllocatedUnfairLock<AccountEmail?>(initialState: nil)
    private var lastKnownMetrics: [UsageMetric] = []

    // Fixed window durations (Codex policy mirrors Claude's windows)
    private static let sessionWindowMinutes = DurationMinutes(rawValue: 300)
    private static let weeklyWindowMinutes = DurationMinutes(rawValue: 10080)
    // Codex credit pool size per the current plan definition
    private static let creditPoolTotal: Double = 1000

    // Known-valid literal — force-unwrap is safe here
    private static let apiURL = URL(string: "https://chatgpt.com/backend-api/wham/usage")! // known-valid literal

    // Actor-isolated: safe without nonisolated(unsafe) since all access is on the actor
    private let isoFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    public init(
        auth: CodexAuthProviding = CodexAuth(),
        logger: FileLogger = Loggers.codex,
        session: URLSession = .shared
    ) {
        self.auth = auth
        self.logger = logger
        self.session = session
    }

    // MARK: - UsageConnector

    nonisolated public func resolveActiveAccount() -> AccountEmail? {
        _cachedEmail.withLock { $0 }
    }

    /// Clears the cached email so the next `fetchUsages()` call resolves a fresh email
    /// from the API response. Called by the account monitor on account_id changes.
    public func invalidateEmailCache() {
        _cachedEmail.withLock { $0 = nil }
        logger.log(.info, "Codex email cache invalidated")
    }

    public func fetchUsages() async throws -> [VendorUsageEntry] {
        let credentials: CodexCredentials
        do {
            credentials = try await auth.load()
        } catch {
            logger.log(.error, "Codex credentials load failed: \(error)")
            return errorEntries(type: "token_error")
        }

        logger.log(.info, "Fetching Codex usages for accountId=\(credentials.accountId)")

        var request = URLRequest(url: Self.apiURL)
        request.setValue("Bearer \(credentials.accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue(credentials.accountId.rawValue, forHTTPHeaderField: "ChatGPT-Account-Id")
        // Reproduces the User-Agent used in the OpenUsage analysis to avoid bot filtering
        request.setValue("OpenUsage", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = CodexConstants.requestTimeoutSeconds

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            logger.log(.error, "Codex API request failed: \(error)")
            return errorEntries(type: "api_error", credentials: credentials)
        }

        let httpResponse = response as? HTTPURLResponse
        let httpCode = httpResponse?.statusCode ?? -1
        logger.log(.info, "Codex API response: HTTP \(httpCode)")

        if httpCode == 401 {
            logger.log(.warning, "Codex API returned HTTP 401 — token expired or revoked")
            return errorEntries(type: "token_expired", credentials: credentials)
        }

        if httpCode == 429 {
            let body = String(data: data, encoding: .utf8) ?? "<non-UTF8 body, \(data.count) bytes>"
            logger.log(.warning, "Codex API rate-limited (HTTP 429): \(body)")
            return errorEntries(
                type: "http_429",
                credentials: credentials,
                isActive: true,
                preservedMetrics: lastKnownMetrics
            )
        }

        guard let http = httpResponse, http.statusCode == 200 else {
            logger.log(.error, "Codex API returned HTTP \(httpCode)")
            return errorEntries(type: "http_\(httpCode)", credentials: credentials)
        }

        logger.log(.debug, "Codex API payload: \(Self.maskedPayload(data))")

        do {
            let (metrics, emailFromResponse) = try parseAPIResponse(data, httpResponse: http)
            guard let (account, source) = resolvePersistedAccount(
                responseEmail: emailFromResponse,
                credentials: credentials
            ) else {
                logger.log(
                    .warning,
                    "Codex identity_unresolved during success response for accountId=\(credentials.accountId) — no usage entry written"
                )
                return []
            }
            lastKnownMetrics = metrics
            logger.log(
                .info,
                "Codex fetched \(metrics.count) metric(s) for account=\(account) via \(source.rawValue)"
            )
            return [VendorUsageEntry(
                vendor: vendor,
                account: account,
                isActive: true,
                lastAcquiredOn: ISODate(date: Date()),
                lastError: nil,
                metrics: metrics
            )]
        } catch {
            logger.log(.error, "Codex response parse failed: \(error)")
            logger.log(.warning, "Codex failed payload dump: \(Self.maskedPayload(data))")
            return errorEntries(type: "parse_error", credentials: credentials)
        }
    }

    // MARK: - Response parsing

    private func parseAPIResponse(_ data: Data, httpResponse: HTTPURLResponse) throws -> ([UsageMetric], AccountEmail?) {
        let jsonObject = try JSONSerialization.jsonObject(with: data)
        guard let json = jsonObject as? [String: Any] else {
            throw CodexConnectorError.unexpectedAPIFormat(receivedKeys: [])
        }

        let email = normalizedEmail(json["email"] as? String)
        var metrics: [UsageMetric] = []

        // Primary and secondary rate-limit windows
        let rateLimit = json["rate_limit"] as? [String: Any]
        if let window = rateLimit?["primary_window"] as? [String: Any],
           let w = extractWindow(from: window, fallbackDuration: Self.sessionWindowMinutes) {
            metrics.append(.timeWindow(name: "Session (5h)", resetAt: w.resetAt, windowDuration: w.duration, usagePercent: w.percent))
        }
        if let window = rateLimit?["secondary_window"] as? [String: Any],
           let w = extractWindow(from: window, fallbackDuration: Self.weeklyWindowMinutes) {
            metrics.append(.timeWindow(name: "Weekly (7d)", resetAt: w.resetAt, windowDuration: w.duration, usagePercent: w.percent))
        }

        // Code review rate limit (optional — absent on plans without code review)
        let codeReviewRateLimit = json["code_review_rate_limit"] as? [String: Any]
        if let window = codeReviewRateLimit?["primary_window"] as? [String: Any],
           let w = extractWindow(from: window, fallbackDuration: Self.weeklyWindowMinutes) {
            metrics.append(.timeWindow(name: "Code Review (7d)", resetAt: w.resetAt, windowDuration: w.duration, usagePercent: w.percent))
        }

        // Per-model additional rate limits (e.g. Spark plan with per-model quotas)
        let additionalRateLimits = json["additional_rate_limits"] as? [[String: Any]] ?? []
        for limitEntry in additionalRateLimits {
            guard let limitName = limitEntry["limit_name"] as? String else { continue }
            let limitRateLimit = limitEntry["rate_limit"] as? [String: Any]
            if let window = limitRateLimit?["primary_window"] as? [String: Any],
               let w = extractWindow(from: window, fallbackDuration: Self.sessionWindowMinutes) {
                metrics.append(.timeWindow(name: "\(limitName) (5h)", resetAt: w.resetAt, windowDuration: w.duration, usagePercent: w.percent))
            }
            if let window = limitRateLimit?["secondary_window"] as? [String: Any],
               let w = extractWindow(from: window, fallbackDuration: Self.weeklyWindowMinutes) {
                metrics.append(.timeWindow(name: "\(limitName) Weekly (7d)", resetAt: w.resetAt, windowDuration: w.duration, usagePercent: w.percent))
            }
        }

        // Credits: body-first, header as fallback
        let credits = json["credits"] as? [String: Any]
        let hasCredits = credits?["has_credits"] as? Bool ?? false
        if hasCredits, let balance = credits?["balance"] as? Double, balance >= 0 {
            // balance is the remaining allowance; clamp to avoid negative values if total exceeds the assumed pool
            metrics.append(.payAsYouGo(name: "Credits used", currentAmount: max(0, Self.creditPoolTotal - balance), currency: "credits"))
        } else if let headerValue = httpResponse.value(forHTTPHeaderField: "x-codex-credits-balance"),
                  let balance = Double(headerValue), balance >= 0 {
            metrics.append(.payAsYouGo(name: "Credits used", currentAmount: max(0, Self.creditPoolTotal - balance), currency: "credits"))
        }

        if metrics.isEmpty {
            logger.log(.warning, "No known usage window in Codex payload — top-level keys: \(Array(json.keys))")
            throw CodexConnectorError.unexpectedAPIFormat(receivedKeys: Array(json.keys))
        }

        return (metrics, email)
    }

    // MARK: - Window extraction

    private struct WindowValues {
        let percent: UsagePercent
        let resetAt: ISODate?
        let duration: DurationMinutes
    }

    private func extractWindow(from window: [String: Any], fallbackDuration: DurationMinutes) -> WindowValues? {
        guard let usedPercent = window["used_percent"] as? Double else {
            logger.log(.debug, "Window block missing used_percent — skipped")
            return nil
        }
        let resetAt: ISODate?
        if let epochSecs = window["reset_at"] as? Double, epochSecs > 0 {
            resetAt = ISODate(date: Date(timeIntervalSince1970: epochSecs))
        } else {
            resetAt = nil
        }
        let duration: DurationMinutes
        if let secs = window["limit_window_seconds"] as? Double, secs > 0 {
            duration = DurationMinutes(rawValue: Int(secs) / 60)
        } else {
            duration = fallbackDuration
        }
        return WindowValues(
            percent: UsagePercent(rawValue: Int(usedPercent.rounded())),
            resetAt: resetAt,
            duration: duration
        )
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

    // MARK: - Helpers

    private func resolvePersistedAccount(
        responseEmail: AccountEmail? = nil,
        credentials: CodexCredentials? = nil
    ) -> (AccountEmail, IdentitySource)? {
        if let responseEmail {
            _cachedEmail.withLock { $0 = responseEmail }
            return (responseEmail, .responseBody)
        }
        if let accountEmail = credentials?.accountEmail {
            _cachedEmail.withLock { $0 = accountEmail }
            return (accountEmail, .credentials)
        }
        if let cached = _cachedEmail.withLock({ $0 }) {
            return (cached, .cache)
        }
        return nil
    }

    private func errorEntries(
        type: String,
        credentials: CodexCredentials? = nil,
        isActive: Bool = false,
        preservedMetrics: [UsageMetric] = []
    ) -> [VendorUsageEntry] {
        guard let (account, source) = resolvePersistedAccount(credentials: credentials) else {
            let accountId = credentials?.accountId.rawValue ?? "<unavailable>"
            logger.log(.warning, "Codex identity_unresolved during \(type) for accountId=\(accountId) — no usage entry written")
            return []
        }
        logger.log(.debug, "Codex resolved account=\(account) via \(source.rawValue) for \(type)")
        return [errorEntry(account: account, type: type, isActive: isActive, preservedMetrics: preservedMetrics)]
    }

    private func normalizedEmail(_ rawValue: String?) -> AccountEmail? {
        guard let rawValue else { return nil }
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return AccountEmail(rawValue: trimmed)
    }

    private func errorEntry(account: AccountEmail, type: String, isActive: Bool = false, preservedMetrics: [UsageMetric] = []) -> VendorUsageEntry {
        VendorUsageEntry(
            vendor: vendor,
            account: account,
            isActive: isActive,
            lastAcquiredOn: nil,
            lastError: UsageError(timestamp: ISODate(date: Date()), type: type),
            metrics: preservedMetrics
        )
    }
}

public enum CodexConnectorError: Error, CustomStringConvertible {
    case unexpectedAPIFormat(receivedKeys: [String])

    public var description: String {
        switch self {
        case let .unexpectedAPIFormat(keys):
            "Codex API response does not match expected format — top-level keys: \(keys)"
        }
    }
}
