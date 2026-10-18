import Foundation

public actor ClaudeTUIConnector: UsageConnector {
    nonisolated public let vendor: Vendor = .claudeTUI

    private let claudeConfigPath: String
    private let logger: FileLogger
    private let session: URLSession
    private let credentialLocator: any CredentialLocator<ClaudeCredentials>
    private let tokenProvider: (@Sendable () async throws -> String)?
    private let accountProvider: (@Sendable () -> AccountEmail?)?

    private var lastKnownMetrics: [UsageMetric] = []
    /// Sticky flag set when the locator's local pre-check or HTTP 401 has
    /// surfaced an auth failure. While true, subsequent HTTP 429s are
    /// attributed to `token_expired` instead of `http_429` so the auth
    /// diagnostic is not masked by the chronic 401→429 cascade Anthropic
    /// produces against a stale bearer (see docs/vendors/claude-tui.md
    /// Stale-token failure mode). Cleared on any HTTP 200.
    private var lastAuthFailureSeen: Bool = false

    private let parser = ClaudeUsageResponseParser()


    public init(
        claudeConfigPath: String? = nil,
        logger: FileLogger = Loggers.claudeTUI,
        session: URLSession = .shared,
        credentialLocator: any CredentialLocator<ClaudeCredentials> = ClaudeTUICredentialLocator(),
        tokenProvider: (@Sendable () async throws -> String)? = nil,
        accountProvider: (@Sendable () -> AccountEmail?)? = nil
    ) {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        self.claudeConfigPath = claudeConfigPath ?? "\(home)/.claude.json"
        self.logger = logger
        self.session = session
        self.credentialLocator = credentialLocator
        self.tokenProvider = tokenProvider
        self.accountProvider = accountProvider
    }

    /// Legacy initializer preserved for tests that pre-date the credential
    /// locator extraction. Routes the `keychainServiceName` override into a
    /// freshly-built locator so the rest of the connector stays uniform.
    public init(
        claudeConfigPath: String? = nil,
        logger: FileLogger = Loggers.claudeTUI,
        session: URLSession = .shared,
        keychainServiceName: String,
        tokenProvider: (@Sendable () async throws -> String)? = nil,
        accountProvider: (@Sendable () -> AccountEmail?)? = nil
    ) {
        self.init(
            claudeConfigPath: claudeConfigPath,
            logger: logger,
            session: session,
            credentialLocator: ClaudeTUICredentialLocator(
                keychainServiceName: keychainServiceName,
                logger: logger
            ),
            tokenProvider: tokenProvider,
            accountProvider: accountProvider
        )
    }

    // MARK: - UsageConnector

    nonisolated public func resolveActiveAccount() -> AccountEmail? {
        if let provider = accountProvider {
            return provider()
        }
        guard let data = FileManager.default.contents(atPath: claudeConfigPath) else {
            logger.log(.warning, "Cannot read \(claudeConfigPath)")
            return nil
        }
        do {
            let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            let oauth = json?["oauthAccount"] as? [String: Any]
            return (oauth?["emailAddress"] as? String).map(AccountEmail.init(rawValue:))
        } catch {
            logger.log(.error, "Failed to parse \(claudeConfigPath): \(error)")
            return nil
        }
    }

    public func fetchUsages() async throws -> [VendorUsageEntry] {
        guard let earlyAccount = resolveActiveAccount() else {
            logger.log(.warning, "Cannot resolve active account — skipping fetch")
            return [errorEntry(account: "unknown", type: "account_unknown")]
        }
        logger.log(.info, "Fetching usages for account=\(earlyAccount)")

        let token: String
        do {
            if let provider = tokenProvider {
                token = try await provider()
            } else {
                token = try await credentialLocator.locate().accessToken
            }
        } catch ClaudeAuthError.tokenExpired(_, let expiredAt) {
            // Stale token detected locally — skip the HTTP call entirely. Spamming
            // /api/oauth/usage with an expired bearer is what triggers Anthropic's
            // chronic 429 (see docs/vendors/claude-tui.md Stale-token failure mode).
            // Metrics are preserved: token expiry invalidates our ability to refresh,
            // not the data itself — values whose window has not yet rolled stay
            // accurate until their resetAt; the UI handles the rest via isUnknown.
            logger.log(.warning, "Skipping fetch: token expired at \(expiredAt). Re-run the `claude` CLI to refresh.")
            lastAuthFailureSeen = true
            return [errorEntry(account: earlyAccount, type: "token_expired", isActive: true, preservedMetrics: lastKnownMetrics)]
        } catch {
            logger.log(.error, "Token retrieval failed: \(error)")
            if case ClaudeAuthError.apiKeyOnlyUnsupported = error {
                return [errorEntry(account: earlyAccount, type: "api_key_usage_unsupported")]
            }
            return [errorEntry(account: earlyAccount, type: "token_error")]
        }

        // Re-read at HTTP dispatch time: if the user switched accounts while the token was being
        // fetched, the response must be attributed to whoever was active when the request went out.
        let account = resolveActiveAccount() ?? earlyAccount

        guard let url = URL(string: "https://api.anthropic.com/api/oauth/usage") else {
            return [errorEntry(account: account, type: "api_error")]
        }
        var request = URLRequest(url: url)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        // Required by the OAuth usage endpoint — beta flag must match the rollout date
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        request.timeoutInterval = 5

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            logger.log(.error, "API request failed: \(error)")
            return [errorEntry(account: account, type: "api_error")]
        }

        let httpCode = (response as? HTTPURLResponse)?.statusCode ?? -1
        logger.log(.info, "API response: HTTP \(httpCode)")

        if httpCode == 401 {
            // The bearer is rejected by Anthropic. Preserve lastKnownMetrics so
            // the UI keeps showing data whose window has not yet rolled — what
            // the user consumed is unchanged; we just can't refresh it.
            logger.log(.error, "API returned HTTP 401 — token expired. Re-run the `claude` CLI to refresh.")
            lastAuthFailureSeen = true
            return [errorEntry(account: account, type: "token_expired", isActive: true, preservedMetrics: lastKnownMetrics)]
        }

        if httpCode == 429 {
            let body = String(data: data, encoding: .utf8) ?? "<non-UTF8 body, \(data.count) bytes>"
            // A 429 that follows a recent auth failure is downstream of it —
            // Anthropic switches from 401 to 429 when an expired bearer keeps
            // hammering the endpoint. Re-attribute to token_expired so the auth
            // signal survives the cascade, otherwise each 429 overwrites
            // lastError and the user sees "rate limited" instead of the
            // actionable "token expired".
            if lastAuthFailureSeen {
                logger.log(.warning, "API HTTP 429 after a recent auth failure — surfacing as token_expired (cascade): \(body)")
                return [errorEntry(account: account, type: "token_expired", isActive: true, preservedMetrics: lastKnownMetrics)]
            }
            logger.log(.warning, "API rate-limited (HTTP 429): \(body)")
            return [errorEntry(account: account, type: "http_429", isActive: true, preservedMetrics: lastKnownMetrics)]
        }

        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            logger.log(.error, "API returned HTTP \(httpCode)")
            return [errorEntry(account: account, type: "http_\(httpCode)")]
        }

        logger.log(.debug, "API payload: \(Self.maskedPayload(data))")

        do {
            let usage = try parser.parse(data)
            logger.log(.info, "Fetched successfully: session=\(usage.sessionPercent.map { "\($0)%" } ?? "nil") weekly=\(usage.weeklyPercent.map { "\($0)%" } ?? "nil") sonnet=\(usage.sonnetWeekly.map { "\($0.percent)%" } ?? "nil") opus=\(usage.opusWeekly.map { "\($0.percent)%" } ?? "nil") breakdown=\(usage.breakdownRows.count) extraUsage=\(usage.extraUsage.map { "\($0.amount) \($0.currency)" } ?? "nil")")
            // A window is emitted whenever utilization is known, even if resets_at is null
            // (fresh account, between cycles). A null reset date surfaces in the UI as "???"
            // rather than silently omitting the metric.
            let metrics = parser.metrics(from: usage)
            lastKnownMetrics = metrics
            // A successful round-trip means the bearer is healthy — clear any
            // sticky auth-failure flag so future 429s are treated as genuine
            // rate-limits again.
            lastAuthFailureSeen = false
            return [VendorUsageEntry(
                vendor: vendor,
                account: account,
                isActive: true,
                lastAcquiredOn: ISODate(date: Date()),
                lastError: nil,
                metrics: metrics
            )]
        } catch {
            logger.log(.error, "Response parse failed: \(error)")
            logger.log(.warning, "Failed payload dump: \(Self.maskedPayload(data))")
            return [errorEntry(account: account, type: "parse_error")]
        }
    }

    // MARK: - Response parsing

    private static let sensitiveKeyPatterns = ["token", "key", "secret", "password", "email", "credential"]

    private static func maskedPayload(_ data: Data) -> String {
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

    private static func maskSensitiveFields(_ dict: [String: Any]) -> [String: Any] {
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

    private func errorEntry(account: AccountEmail, type: String, isActive: Bool = false, preservedMetrics: [UsageMetric] = []) -> VendorUsageEntry {
        return VendorUsageEntry(
            vendor: vendor,
            account: account,
            isActive: isActive,
            lastAcquiredOn: nil,
            lastError: UsageError(timestamp: ISODate(date: Date()), type: type),
            metrics: preservedMetrics
        )
    }
}

public enum ConnectorError: Error, CustomStringConvertible {
    case keychainAccessDenied(serviceName: String, exitCode: Int32)
    case keychainEmpty(serviceName: String)
    case keychainTimeout(serviceName: String, timeoutSeconds: Int)
    case tokenParseError(rawValue: String)
    case unexpectedAPIFormat(receivedKeys: [String])

    public var description: String {
        switch self {
        case let .keychainAccessDenied(svc, code):
            "Keychain access denied for service '\(svc)' (exit \(code))"
        case let .keychainEmpty(svc):
            "Keychain item is empty for service '\(svc)'"
        case let .keychainTimeout(svc, secs):
            "Keychain access timed out after \(secs)s for service '\(svc)'"
        case let .tokenParseError(raw):
            "Failed to parse OAuth token — raw value preview: '\(raw.prefix(80))'"
        case let .unexpectedAPIFormat(keys):
            "API response does not match expected format — top-level keys: \(keys)"
        }
    }
}
