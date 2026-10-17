import Foundation

/// Fetches Claude usage for every account found across the local Claude Desktop
/// profiles. Shares the OAuth usage endpoint and response parsing with
/// `ClaudeCodeConnector` but sources its bearers from the Electron token cache
/// instead of the `claude` CLI keychain entry, and emits one
/// `VendorUsageEntry` per profile/account.
///
/// The source is opt-in: when disabled, `fetchUsages()` returns an empty array
/// and never calls the locator, so no Claude Desktop Safe Storage Keychain read
/// — and therefore no authorisation prompt — is triggered. This is what keeps
/// the vendor compliant with the bootstrap/no-prompt rule
/// (`.claude/rules/swift-quality.md` §9): the Keychain secret read only happens
/// after the user has explicitly enabled the source.
public actor ClaudeDesktopConnector: UsageConnector {
    nonisolated public let vendor: Vendor = .claudeDesktop

    private let logger: FileLogger
    private let session: URLSession
    private let credentialLocator: any CredentialLocator<[ClaudeDesktopCredential]>
    private let isEnabled: @Sendable () -> Bool
    private let clock: @Sendable () -> Date
    private let parser = ClaudeUsageResponseParser()

    /// Preserves per-account metrics across auth failures (keyed by account
    /// label) so an expired token does not wipe still-valid numbers — mirrors
    /// `ClaudeCodeConnector.lastKnownMetrics`, per account.
    private var lastKnownMetricsByAccount: [String: [UsageMetric]] = [:]

    /// See `ClaudeCredentialLocator.expirySkewSeconds`.
    private static let expirySkewSeconds: TimeInterval = 60

    public init(
        logger: FileLogger = Loggers.claudeDesktop,
        session: URLSession = .shared,
        credentialLocator: any CredentialLocator<[ClaudeDesktopCredential]> = ClaudeDesktopCredentialLocator(),
        isEnabled: @escaping @Sendable () -> Bool,
        clock: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.logger = logger
        self.session = session
        self.credentialLocator = credentialLocator
        self.isEnabled = isEnabled
        self.clock = clock
    }

    // MARK: - UsageConnector

    nonisolated public func resolveActiveAccount() -> AccountEmail? {
        // Claude Desktop has no single "active" account across profiles — each
        // profile is its own session. The menu surfaces all of them equally.
        nil
    }

    nonisolated public func knownAccounts() -> [AccountEmail] {
        // Cannot resolve synchronously without a Keychain read; the poll-driven
        // merge keeps previously-seen accounts visible via usages.json.
        []
    }

    public func fetchUsages() async throws -> [VendorUsageEntry] {
        guard isEnabled() else {
            logger.log(.debug, "Claude Desktop source disabled — skipping fetch")
            return []
        }

        let credentials: [ClaudeDesktopCredential]
        do {
            credentials = try await credentialLocator.locate()
        } catch ClaudeDesktopAuthError.noProfiles {
            logger.log(.info, "No Claude Desktop profiles found — nothing to fetch")
            return []
        } catch {
            logger.log(.error, "Credential resolution failed: \(error)")
            return []
        }

        var entries: [VendorUsageEntry] = []
        for credential in credentials {
            entries.append(await fetchOne(credential: credential))
        }
        return entries
    }

    // MARK: - Per-account fetch

    private func fetchOne(credential: ClaudeDesktopCredential) async -> VendorUsageEntry {
        let account = AccountEmail(rawValue: credential.accountLabel)
        let preserved = lastKnownMetricsByAccount[credential.accountLabel] ?? []

        if let expiresAt = credential.expiresAt,
           clock().addingTimeInterval(Self.expirySkewSeconds) >= expiresAt {
            logger.log(.warning, "Token for '\(credential.accountLabel)' expired at \(expiresAt) — skipping fetch. Re-open Claude Desktop to refresh.")
            return errorEntry(account: account, type: "token_expired", isActive: false, preservedMetrics: preserved)
        }

        guard let url = URL(string: "https://api.anthropic.com/api/oauth/usage") else {
            return errorEntry(account: account, type: "api_error")
        }
        var request = URLRequest(url: url)
        request.setValue("Bearer \(credential.accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        request.timeoutInterval = 5

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            logger.log(.error, "API request failed for '\(credential.accountLabel)': \(error)")
            return errorEntry(account: account, type: "api_error")
        }

        let httpCode = (response as? HTTPURLResponse)?.statusCode ?? -1
        logger.log(.info, "API response for '\(credential.accountLabel)': HTTP \(httpCode)")

        if httpCode == 401 {
            logger.log(.error, "HTTP 401 for '\(credential.accountLabel)' — token expired. Re-open Claude Desktop to refresh.")
            return errorEntry(account: account, type: "token_expired", isActive: false, preservedMetrics: preserved)
        }
        if httpCode == 429 {
            return errorEntry(account: account, type: "http_429", isActive: false, preservedMetrics: preserved)
        }
        guard httpCode == 200 else {
            return errorEntry(account: account, type: "http_\(httpCode)")
        }

        do {
            let metrics = try parser.parseMetrics(data)
            lastKnownMetricsByAccount[credential.accountLabel] = metrics
            return VendorUsageEntry(
                vendor: vendor,
                account: account,
                isActive: false,
                lastAcquiredOn: ISODate(date: clock()),
                lastError: nil,
                metrics: metrics
            )
        } catch {
            logger.log(.error, "Response parse failed for '\(credential.accountLabel)': \(error)")
            return errorEntry(account: account, type: "parse_error")
        }
    }

    private func errorEntry(account: AccountEmail, type: String, isActive: Bool = false, preservedMetrics: [UsageMetric] = []) -> VendorUsageEntry {
        VendorUsageEntry(
            vendor: vendor,
            account: account,
            isActive: isActive,
            lastAcquiredOn: nil,
            lastError: UsageError(timestamp: ISODate(date: clock()), type: type),
            metrics: preservedMetrics
        )
    }
}
