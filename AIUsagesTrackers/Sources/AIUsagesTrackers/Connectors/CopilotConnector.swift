import Foundation
import os

public actor CopilotConnector: UsageConnector {
    nonisolated public let vendor: Vendor = .copilot

    private let auth: any CopilotCredentialLocating
    private let logger: FileLogger
    private let session: URLSession

    // Thread-safe login cache readable from nonisolated resolveActiveAccount()
    // without blocking the cooperative thread pool.
    private let _cachedLogin = OSAllocatedUnfairLock<AccountEmail?>(initialState: nil)
    private let _knownAccounts = OSAllocatedUnfairLock<[AccountEmail]>(initialState: [])
    private var lastKnownMetricsByAccount: [AccountEmail: [UsageMetric]] = [:]

    /// Copilot premium-request quotas reset on a monthly cadence; the API exposes
    /// only an absolute reset date, so we synthesize a 30-day window for the UI's
    /// progress rendering — matching openusage's default.
    private static let monthlyWindowMinutes = DurationMinutes(rawValue: 30 * 24 * 60)

    private static let apiURL = URL(string: "https://api.github.com/copilot_internal/user")! // known-valid literal

    public init(
        auth: any CopilotCredentialLocating = CopilotCredentialLocator(),
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

    nonisolated public func knownAccounts() -> [AccountEmail] {
        _knownAccounts.withLock { $0 }
    }

    /// Clears the cached login so the next `fetchUsages()` call resolves a fresh
    /// identity from auth. Called by the active-account monitor on `gh auth switch`.
    public func invalidateLoginCache() {
        _cachedLogin.withLock { $0 = nil }
        _knownAccounts.withLock { $0 = [] }
        lastKnownMetricsByAccount = [:]
        logger.log(.info, "Copilot login cache invalidated")
    }

    public func fetchUsages() async throws -> [VendorUsageEntry] {
        let credentialsList: [CopilotCredentials]
        let activeLogin: AccountEmail
        do {
            let batch = try await auth.locateAll()
            credentialsList = batch.credentials
            activeLogin = batch.activeLogin
        } catch {
            logger.log(.error, "Copilot credentials load failed: \(error)")
            _knownAccounts.withLock { $0 = [] }
            return errorEntries(type: Self.credentialErrorType(for: error))
        }

        _cachedLogin.withLock { $0 = activeLogin }

        logger.log(
            .info,
            "Fetching Copilot usages for \(credentialsList.count) login(s): \(credentialsList.map(\.login.rawValue).joined(separator: ", "))"
        )

        var entries = await withTaskGroup(of: VendorUsageEntry?.self) { group in
            for credentials in credentialsList {
                group.addTask {
                    await self.fetchUsageEntry(for: credentials, activeLogin: activeLogin)
                }
            }
            var fetched: [VendorUsageEntry] = []
            for await entry in group {
                if let entry {
                    fetched.append(entry)
                }
            }
            return fetched
        }

        if let missing = missingActiveLoginEntry(activeLogin: activeLogin, entries: entries) {
            entries.append(missing)
        }

        let sorted = entries.sorted { $0.account.rawValue < $1.account.rawValue }
        _knownAccounts.withLock { $0 = sorted.map(\.account) }
        return sorted
    }

    private func missingActiveLoginEntry(
        activeLogin: AccountEmail,
        entries: [VendorUsageEntry]
    ) -> VendorUsageEntry? {
        guard !entries.contains(where: { $0.isActive }) else { return nil }
        logger.log(
            .warning,
            "Copilot active login=\(activeLogin) has no usable token — run `gh auth switch` or `gh auth login`"
        )
        return errorEntry(
            type: UsageErrorType.tokenError,
            login: activeLogin,
            isActive: true,
            preservedMetrics: []
        )
    }

    // MARK: - Per-account fetch

    private func fetchUsageEntry(
        for credentials: CopilotCredentials,
        activeLogin: AccountEmail
    ) async -> VendorUsageEntry? {
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
            logger.log(.error, "Copilot API request failed for login=\(credentials.login): \(error)")
            return errorEntry(
                type: "api_error",
                login: credentials.login,
                isActive: credentials.isActive
            )
        }

        let httpResponse = response as? HTTPURLResponse
        let httpCode = httpResponse?.statusCode ?? -1
        if httpCode != 200 {
            logger.log(.debug, "Copilot API response for login=\(credentials.login): HTTP \(httpCode)")
        }

        let preservedMetrics = preservedMetrics(for: credentials.login)

        if httpCode == 401 || httpCode == 403 {
            logger.log(.warning, "Copilot API returned HTTP \(httpCode) for login=\(credentials.login) — token expired/revoked or missing Copilot entitlement")
            return errorEntry(
                type: UsageErrorType.tokenExpired,
                login: credentials.login,
                isActive: credentials.isActive,
                preservedMetrics: preservedMetrics
            )
        }

        if httpCode == 429 {
            let bodyPreview = String(data: data.prefix(200), encoding: .utf8) ?? "<non-UTF8 body, \(data.count) bytes>"
            logger.log(.warning, "Copilot API rate-limited (HTTP 429) for login=\(credentials.login): \(bodyPreview)")
            return errorEntry(
                type: "http_429",
                login: credentials.login,
                isActive: credentials.isActive,
                preservedMetrics: preservedMetrics
            )
        }

        guard httpCode == 200 else {
            logger.log(.error, "Copilot API returned HTTP \(httpCode) for login=\(credentials.login)")
            return errorEntry(
                type: "http_\(httpCode)",
                login: credentials.login,
                isActive: credentials.isActive
            )
        }

        logger.log(.debug, "Copilot API payload for login=\(credentials.login): \(Self.maskedPayload(data))")

        do {
            let parsed = try parseAPIResponse(data)
            let account = parsed.login.map(AccountEmail.init(rawValue:)) ?? credentials.login
            if parsed.login != nil, parsed.login != credentials.login.rawValue {
                logger.log(
                    .debug,
                    "Copilot API login=\(account) differs from credential login=\(credentials.login)"
                )
            }
            let isActive = account == activeLogin
            storeMetrics(parsed.metrics, for: account, alias: credentials.login)
            logger.log(.info, "Copilot fetched \(parsed.metrics.count) metric(s) for login=\(account)")
            return VendorUsageEntry(
                vendor: vendor,
                account: account,
                isActive: isActive,
                lastAcquiredOn: ISODate(date: Date()),
                lastError: nil,
                metrics: parsed.metrics
            )
        } catch {
            logger.log(.error, "Copilot response parse failed for login=\(credentials.login): \(error)")
            logger.log(.warning, "Copilot failed payload dump: \(Self.maskedPayload(data))")
            return errorEntry(
                type: "parse_error",
                login: credentials.login,
                isActive: credentials.isActive
            )
        }
    }

    private func preservedMetrics(for account: AccountEmail) -> [UsageMetric] {
        lastKnownMetricsByAccount[account] ?? []
    }

    private func storeMetrics(_ metrics: [UsageMetric], for account: AccountEmail, alias: AccountEmail? = nil) {
        lastKnownMetricsByAccount[account] = metrics
        if let alias, alias != account {
            lastKnownMetricsByAccount[alias] = metrics
        }
    }

    // MARK: - Response parsing

    private struct ParsedAPIResponse {
        let metrics: [UsageMetric]
        let login: String?
    }

    private func parseAPIResponse(_ data: Data) throws -> ParsedAPIResponse {
        let jsonObject = try JSONSerialization.jsonObject(with: data)
        guard let json = jsonObject as? [String: Any] else {
            throw CopilotConnectorError.unexpectedAPIFormat(receivedKeys: [])
        }

        let login = json["login"] as? String
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

        return ParsedAPIResponse(metrics: metrics, login: login)
    }

    private func makeSnapshotMetric(name: String, snapshot: Any?, resetAt: ISODate?) -> UsageMetric? {
        guard let dict = snapshot as? [String: Any] else { return nil }
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

    private func errorEntries(type: String) -> [VendorUsageEntry] {
        let resolved: AccountEmail? = _cachedLogin.withLock { $0 }
        guard let account = resolved else {
            logger.log(.warning, "Copilot identity_unresolved during \(type) — no usage entry written")
            return []
        }
        return [errorEntry(
            type: type,
            login: account,
            isActive: true,
            preservedMetrics: preservedMetrics(for: account)
        )]
    }

    private static func credentialErrorType(for error: Error) -> String {
        guard let error = error as? CopilotCredentialLocatorError else {
            return UsageErrorType.credentialError
        }
        switch error {
        case .notLoggedIn, .noTokenAvailable:
            return UsageErrorType.tokenError
        case .hostsFileReadFailed, .hostsFileParseFailed, .keychainAccessDenied, .keychainTimeout, .keychainParseFailed:
            return UsageErrorType.credentialError
        }
    }

    private func errorEntry(
        type: String,
        login: AccountEmail,
        isActive: Bool,
        preservedMetrics: [UsageMetric] = []
    ) -> VendorUsageEntry {
        VendorUsageEntry(
            vendor: vendor,
            account: login,
            isActive: isActive,
            lastAcquiredOn: nil,
            lastError: UsageError(timestamp: ISODate(date: Date()), type: type),
            metrics: preservedMetrics
        )
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
