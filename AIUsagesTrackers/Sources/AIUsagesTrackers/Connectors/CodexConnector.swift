import Foundation
import os

public actor CodexConnector: UsageConnector {
    nonisolated public let vendor: Vendor = .codex

    private enum IdentitySource: String {
        case responseBody = "response_body"
        case credentials = "credentials"
        case cache = "cache"
    }

    private let auth: any CodexCredentialLocating
    private let logger: FileLogger
    private let session: URLSession

    // Thread-safe email cache readable from nonisolated resolveActiveAccount()
    // without blocking the cooperative thread pool.
    private let _cachedEmail = OSAllocatedUnfairLock<AccountEmail?>(initialState: nil)
    private var lastKnownMetrics: [UsageMetric] = []

    // Fixed window durations (Codex policy mirrors Claude's windows)
    private static let sessionWindowMinutes = DurationMinutes(rawValue: 300)
    private static let weeklyWindowMinutes = DurationMinutes(rawValue: 10080)
    private static let secondsPerMinute = 60
    private static let minutesPerHour = 60
    private static let minutesPerDay = 1440
    // A window is exhausted when the API reports it fully consumed.
    private static let exhaustedWindowPercent: Double = 100

    // Known-valid literal — force-unwrap is safe here
    private static let apiURL = URL(string: "https://chatgpt.com/backend-api/wham/usage")! // known-valid literal
    // Known-valid literal — force-unwrap is safe here
    private static let resetCreditsURL = URL(string: "https://chatgpt.com/backend-api/wham/rate-limit-reset-credits")! // known-valid literal

    // Actor-isolated: safe without nonisolated(unsafe) since all access is on the actor
    private let isoFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    public init(
        auth: any CodexCredentialLocating = CodexCredentialLocator(),
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
            credentials = try await auth.locate()
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
            // Network/timeout errors are transient — the auth.json told us which
            // account is logged in, so the active flag still holds. Wiping it would
            // make the "active" badge flicker on every flaky tick.
            logger.log(.error, "Codex API request failed: \(error)")
            return errorEntries(
                type: "api_error",
                credentials: credentials,
                isActive: true,
                preservedMetrics: lastKnownMetrics
            )
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
            // 5xx is transient (server-side); 4xx other than 401/429 is rarer but the
            // account identity itself doesn't change — preserve the active flag so the
            // UI doesn't blink between server hiccups.
            return errorEntries(
                type: "http_\(httpCode)",
                credentials: credentials,
                isActive: true,
                preservedMetrics: lastKnownMetrics
            )
        }

        logger.log(.debug, "Codex API payload: \(Self.maskedPayload(data))")

        do {
            let (metrics, emailFromResponse, parsedStatus) = try parseAPIResponse(data, httpResponse: http)
            var accountStatus = parsedStatus
            if let counts = parsedStatus.resetCredits, counts.available > 0 {
                accountStatus.resetCredits = await fetchResetCreditDetails(counts: counts, credentials: credentials)
            }
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
                metrics: metrics,
                accountStatus: accountStatus
            )]
        } catch {
            // Parse failures are transient (the API responded HTTP 200, just with an
            // unrecognized shape) — the account is still the logged-in one.
            logger.log(.error, "Codex response parse failed: \(error)")
            logger.log(.warning, "Codex failed payload dump: \(Self.maskedPayload(data))")
            return errorEntries(
                type: "parse_error",
                credentials: credentials,
                isActive: true,
                preservedMetrics: lastKnownMetrics
            )
        }
    }

    // MARK: - Response parsing

    private func parseAPIResponse(
        _ data: Data,
        httpResponse: HTTPURLResponse
    ) throws -> ([UsageMetric], AccountEmail?, AccountStatus) {
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
            // Pro / Pro Lite put the weekly window in `primary_window` (with a
            // null secondary), so the label must follow the duration, not the slot.
            metrics.append(.timeWindow(name: Self.windowLabel(for: w.duration), resetAt: w.resetAt, windowDuration: w.duration, usagePercent: w.percent))
        }
        if let window = rateLimit?["secondary_window"] as? [String: Any],
           let w = extractWindow(from: window, fallbackDuration: Self.weeklyWindowMinutes) {
            metrics.append(.timeWindow(name: Self.windowLabel(for: w.duration), resetAt: w.resetAt, windowDuration: w.duration, usagePercent: w.percent))
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
                metrics.append(.timeWindow(name: Self.windowLabel(for: w.duration, prefix: limitName), resetAt: w.resetAt, windowDuration: w.duration, usagePercent: w.percent))
            }
            if let window = limitRateLimit?["secondary_window"] as? [String: Any],
               let w = extractWindow(from: window, fallbackDuration: Self.weeklyWindowMinutes) {
                metrics.append(.timeWindow(name: Self.windowLabel(for: w.duration, prefix: limitName), resetAt: w.resetAt, windowDuration: w.duration, usagePercent: w.percent))
            }
        }

        // Credits: body-first, header as fallback
        let credits = json["credits"] as? [String: Any]
        let hasCredits = credits?["has_credits"] as? Bool ?? false
        // `balance` is the remaining allowance and ships as a decimal string
        // ("260.9493799584"); accept a number too in case the API normalises it.
        if hasCredits, let balance = Self.decimal(credits?["balance"]), balance >= 0 {
            metrics.append(.payAsYouGo(name: Self.creditsBalanceMetricName, currentAmount: balance, currency: "credits"))
        } else if let headerValue = httpResponse.value(forHTTPHeaderField: "x-codex-credits-balance"),
                  let balance = Double(headerValue), balance >= 0 {
            metrics.append(.payAsYouGo(name: Self.creditsBalanceMetricName, currentAmount: balance, currency: "credits"))
        }

        if metrics.isEmpty {
            logger.log(.warning, "No known usage window in Codex payload — top-level keys: \(Array(json.keys))")
            throw CodexConnectorError.unexpectedAPIFormat(receivedKeys: Array(json.keys))
        }

        return (metrics, email, parseAccountStatus(json))
    }

    static let creditsBalanceMetricName = "Credits balance"

    // MARK: - Reset credit details

    /// Expiry dates only live on a dedicated endpoint. Fetched only when the
    /// usage payload reports resets, so accounts without any pay no extra call.
    /// Any failure keeps the counts from the usage payload — the expiry is a
    /// nice-to-have, never a reason to fail the tick.
    private func fetchResetCreditDetails(counts: ResetCredits, credentials: CodexCredentials) async -> ResetCredits {
        var request = URLRequest(url: Self.resetCreditsURL)
        request.setValue("Bearer \(credentials.accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue(credentials.accountId.rawValue, forHTTPHeaderField: "ChatGPT-Account-Id")
        request.setValue("OpenUsage", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = CodexConstants.requestTimeoutSeconds

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            logger.log(.warning, "Codex reset credits request failed — keeping counts only: \(error)")
            return counts
        }
        let httpCode = (response as? HTTPURLResponse)?.statusCode ?? -1
        guard httpCode == 200 else {
            logger.log(.warning, "Codex reset credits returned HTTP \(httpCode) — keeping counts only")
            return counts
        }
        let json: [String: Any]
        do {
            json = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
        } catch {
            logger.log(.warning, "Codex reset credits payload is not JSON — keeping counts only: \(error)")
            return counts
        }
        let grants = (json["credits"] as? [[String: Any]] ?? [])
            .filter { ($0["status"] as? String)?.lowercased() == "available" }
            .map { credit in
                ResetGrant(
                    kind: Self.resetKind(credit["reset_type"] as? String, title: credit["title"] as? String),
                    label: (credit["title"] as? String).flatMap { $0.isEmpty ? nil : $0 },
                    remaining: 1,
                    expiresAt: parseExpiry(credit["expires_at"]),
                    usableNow: counts.applicable > 0
                )
            }
        logger.log(.debug, "Codex reset credits: \(grants.count) available grant(s)")
        return ResetCredits(available: counts.available, applicable: counts.applicable, grants: grants)
    }

    /// Titles read "Full reset (Weekly + 5 hr)"; anything not mentioning the
    /// weekly window is treated as a session-only reset.
    private static func resetKind(_ resetType: String?, title: String?) -> ResetGrantKind {
        let text = (title ?? "").lowercased()
        if text.contains("full") || text.contains("weekly") || title == nil { return .full }
        if text.contains("5") { return .session }
        return ResetGrantKind(rawValue: resetType ?? "full")
    }

    /// `expires_at` is ISO 8601 in the web API and epoch seconds in some clients.
    private func parseExpiry(_ value: Any?) -> ISODate? {
        if let seconds = value as? Double, seconds > 0 {
            return ISODate(date: Date(timeIntervalSince1970: seconds))
        }
        if let raw = value as? String { return parseVendorTimestamp(raw) }
        return nil
    }

    // MARK: - Account status

    private func parseAccountStatus(_ json: [String: Any]) -> AccountStatus {
        let plan = (json["plan_type"] as? String)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .flatMap { $0.isEmpty ? nil : PlanType(rawValue: $0) }

        let unavailableModels: [ModelAvailability] = (json["model_usage"] as? [String: Any] ?? [:])
            .compactMap { slug, value in
                guard let info = value as? [String: Any],
                      info["available"] as? Bool == false else { return nil }
                return ModelAvailability(
                    model: ModelSlug(rawValue: slug),
                    availableAt: (info["available_at"] as? String).flatMap(parseVendorTimestamp),
                    creditsWouldEnable: info["credits_would_enable"] as? Bool ?? false
                )
            }
            .sorted { $0.model.rawValue < $1.model.rawValue }

        let resetCredits = (json["rate_limit_reset_credits"] as? [String: Any]).flatMap { block -> ResetCredits? in
            guard let available = Self.integer(block["available_count"]) else { return nil }
            return ResetCredits(
                available: available,
                applicable: Self.integer(block["applicable_available_count"]) ?? 0
            )
        }

        return AccountStatus(
            plan: plan,
            block: parseBlock(json),
            unavailableModels: unavailableModels,
            resetCredits: resetCredits,
            credits: parseCreditsSummary(json["credits"] as? [String: Any])
        )
    }

    private func parseBlock(_ json: [String: Any]) -> AccountBlock? {
        if let spendControl = json["spend_control"] as? [String: Any],
           spendControl["reached"] as? Bool == true {
            return AccountBlock(reason: .spendControl, resumesAt: nil)
        }
        let rateLimit = json["rate_limit"] as? [String: Any]
        let limitReached = rateLimit?["limit_reached"] as? Bool == true
        let disallowed = rateLimit?["allowed"] as? Bool == false
        guard limitReached || disallowed else { return nil }

        // Several windows can be exhausted at once (5h and weekly); requests
        // resume only once the last of them resets.
        let exhaustedResets = ["primary_window", "secondary_window"]
            .compactMap { rateLimit?[$0] as? [String: Any] }
            .filter { ($0["used_percent"] as? Double ?? 0) >= Self.exhaustedWindowPercent }
            .compactMap { ($0["reset_at"] as? Double).flatMap { $0 > 0 ? $0 : nil } }
        let resumesAt = exhaustedResets.max().map { ISODate(date: Date(timeIntervalSince1970: $0)) }
        return AccountBlock(reason: .rateLimit, resumesAt: resumesAt)
    }

    private func parseCreditsSummary(_ credits: [String: Any]?) -> CreditsSummary? {
        guard let credits else { return nil }
        let summary = CreditsSummary(
            unlimited: credits["unlimited"] as? Bool ?? false,
            overageLimitReached: credits["overage_limit_reached"] as? Bool ?? false,
            approxLocalMessages: Self.messageRange(credits["approx_local_messages"]),
            approxCloudMessages: Self.messageRange(credits["approx_cloud_messages"])
        )
        // A zeroed estimate on an account without credits is the nominal Plus
        // shape — persisting it would only make the UI render an empty row.
        let hasRange = !(summary.approxLocalMessages?.isZero ?? true) || !(summary.approxCloudMessages?.isZero ?? true)
        guard summary.unlimited || summary.overageLimitReached || hasRange else { return nil }
        return summary
    }

    /// `model_usage[].available_at` carries fractional seconds, which the
    /// plain `ISODate` parser rejects.
    private func parseVendorTimestamp(_ raw: String) -> ISODate? {
        if let date = isoFormatter.date(from: raw) { return ISODate(date: date) }
        return ISODate.parsing(raw)
    }

    private static func messageRange(_ value: Any?) -> MessageRange? {
        guard let pair = value as? [Any], pair.count == 2,
              let lower = integer(pair[0]), let upper = integer(pair[1]) else { return nil }
        return MessageRange(lower: lower, upper: upper)
    }

    private static func integer(_ value: Any?) -> Int? {
        if let number = value as? Double { return Int(number) }
        if let string = value as? String { return Int(string) }
        return nil
    }

    private static func decimal(_ value: Any?) -> Double? {
        if let number = value as? Double { return number }
        if let string = value as? String { return Double(string) }
        return nil
    }

    /// Maps a window duration onto the stable metric names menu bar chips key on.
    static func windowLabel(for duration: DurationMinutes, prefix: String? = nil) -> String {
        let minutes = duration.rawValue
        let suffix: String
        if minutes == weeklyWindowMinutes.rawValue {
            suffix = "Weekly (7d)"
        } else if minutes >= minutesPerDay, minutes % minutesPerDay == 0 {
            suffix = "(\(minutes / minutesPerDay)d)"
        } else if minutes >= minutesPerHour, minutes % minutesPerHour == 0 {
            suffix = minutes == sessionWindowMinutes.rawValue ? "Session (5h)" : "(\(minutes / minutesPerHour)h)"
        } else {
            suffix = "(\(minutes)m)"
        }
        guard let prefix else { return suffix }
        // Prefixed per-model limits historically read "<name> (5h)", not "<name> Session (5h)".
        let prefixedSuffix = suffix == "Session (5h)" ? "(5h)" : suffix
        return "\(prefix) \(prefixedSuffix)"
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
        let limitWindowSeconds = (window["limit_window_seconds"] as? Double).flatMap { $0 > 0 ? $0 : nil }
        let resetAfterSeconds = (window["reset_after_seconds"] as? Double).flatMap { $0 > 0 ? $0 : nil }

        // OpenAI ships an idle-account quirk: when no quota has actually been
        // consumed in the rolling window, the API still returns a `reset_at`
        // equal to `now + limit_window_seconds` (detectable via
        // `reset_after_seconds >= limit_window_seconds`). Trusting that value
        // would surface a misleading "ends in 5h" in the popover for users
        // who haven't sent anything. Treat that signature as "window not
        // actually open" → emit the metric with `resetAt: nil` so the row
        // renders "???". See CodexConnectorTests.idleAccountFreshWindowSignatureEmitsNilResetAt.
        let isFreshUntouchedWindow: Bool
        if let limit = limitWindowSeconds, let resetAfter = resetAfterSeconds, resetAfter >= limit {
            isFreshUntouchedWindow = true
        } else {
            isFreshUntouchedWindow = false
        }

        let resetAt: ISODate?
        if isFreshUntouchedWindow {
            resetAt = nil
        } else if let epochSecs = window["reset_at"] as? Double, epochSecs > 0 {
            resetAt = ISODate(date: Date(timeIntervalSince1970: epochSecs))
        } else {
            resetAt = nil
        }
        let duration: DurationMinutes
        if let secs = limitWindowSeconds {
            duration = DurationMinutes(rawValue: Int(secs) / Self.secondsPerMinute)
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
