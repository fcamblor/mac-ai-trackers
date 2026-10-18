import Foundation

/// Fetches Claude usage for every account found across the local Claude Desktop
/// profiles. Shares the OAuth usage endpoint and response parsing with
/// `ClaudeTUIConnector` but sources its bearers from the Electron token cache
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
    private let profileResolver: any ClaudeProfileResolving
    private let processInspector: any ClaudeDesktopProcessInspecting
    private let isEnabled: @Sendable () -> Bool
    private let clock: @Sendable () -> Date
    private let parser = ClaudeUsageResponseParser()

    /// Preserves per-account metrics across auth failures (keyed by resolved
    /// account identity) so an expired token does not wipe still-valid numbers —
    /// mirrors `ClaudeTUIConnector.lastKnownMetrics`, per account.
    private var lastKnownMetricsByAccount: [String: [UsageMetric]] = [:]
    /// Caches the resolved account email per account UUID so the profile
    /// endpoint is hit at most once per account per process, not every poll.
    private var emailCacheByUuid: [String: AccountEmail] = [:]

    /// See `ClaudeTUICredentialLocator.expirySkewSeconds`.
    private static let expirySkewSeconds: TimeInterval = 60

    public init(
        logger: FileLogger = Loggers.claudeDesktop,
        session: URLSession = .shared,
        credentialLocator: any CredentialLocator<[ClaudeDesktopCredential]> = ClaudeDesktopCredentialLocator(),
        profileResolver: (any ClaudeProfileResolving)? = nil,
        processInspector: (any ClaudeDesktopProcessInspecting)? = nil,
        isEnabled: @escaping @Sendable () -> Bool,
        clock: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.logger = logger
        self.session = session
        self.credentialLocator = credentialLocator
        self.profileResolver = profileResolver ?? HTTPClaudeProfileResolver(session: session, logger: logger)
        self.processInspector = processInspector ?? PSClaudeDesktopProcessInspector(logger: logger)
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

        let activePaths = await processInspector.activeProfilePaths()

        var entries: [VendorUsageEntry] = []
        // Resolve live credentials first so expired profiles of the same UUID
        // reuse the email cache instead of leaking a second, label-based account.
        let ordered = credentials.sorted { !tokenLikelyExpired($0) && tokenLikelyExpired($1) }
        for credential in ordered {
            entries.append(await fetchOne(credential: credential, activeProfilePaths: activePaths))
        }
        // Persistence upserts by vendor + account. Returning duplicate identities
        // would let the last profile's auth failure overwrite a successful fetch.
        return entries.groupedForDisplay().compactMap { group in
            guard var entry = group.representativeMember else { return nil }
            entry.isActive = group.members.contains { $0.isActive }
            return entry
        }
    }

    // MARK: - Per-account fetch

    private func tokenLikelyExpired(_ credential: ClaudeDesktopCredential) -> Bool {
        credential.expiresAt.map {
            clock().addingTimeInterval(Self.expirySkewSeconds) >= $0
        } ?? false
    }

    private func fetchOne(credential: ClaudeDesktopCredential, activeProfilePaths: Set<String>) async -> VendorUsageEntry {
        let isActive = activeProfilePaths.contains((credential.profileDirectoryPath as NSString).standardizingPath)
        let tokenLikelyExpired = tokenLikelyExpired(credential)
        let account = await resolveAccount(credential: credential, tokenLikelyExpired: tokenLikelyExpired)
        let preserved = lastKnownMetricsByAccount[account.rawValue] ?? []

        if tokenLikelyExpired {
            logger.log(.warning, "Token for '\(account.rawValue)' expired — skipping fetch. Re-open Claude Desktop to refresh.")
            return errorEntry(account: account, type: "token_expired", isActive: isActive, preservedMetrics: preserved)
        }

        var request = URLRequest(url: ClaudeUsageResponseParser.usageURL)
        request.setValue("Bearer \(credential.accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        request.timeoutInterval = 5

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            logger.log(.error, "API request failed for '\(credential.accountLabel)': \(error)")
            return errorEntry(account: account, type: "api_error", isActive: isActive, preservedMetrics: preserved)
        }

        let httpCode = (response as? HTTPURLResponse)?.statusCode ?? -1
        logger.log(.info, "API response for '\(account.rawValue)': HTTP \(httpCode)")

        if httpCode == 401 {
            logger.log(.error, "HTTP 401 for '\(account.rawValue)' — token expired. Re-open Claude Desktop to refresh.")
            return errorEntry(account: account, type: "token_expired", isActive: isActive, preservedMetrics: preserved)
        }
        if httpCode == 429 {
            return errorEntry(account: account, type: "http_429", isActive: isActive, preservedMetrics: preserved)
        }
        guard httpCode == 200 else {
            return errorEntry(account: account, type: "http_\(httpCode)", isActive: isActive, preservedMetrics: preserved)
        }

        do {
            let snapshot = try parser.parse(data)
            let metrics = parser.metrics(from: snapshot)
            lastKnownMetricsByAccount[account.rawValue] = metrics
            return VendorUsageEntry(
                vendor: vendor,
                account: account,
                isActive: isActive,
                lastAcquiredOn: ISODate(date: clock()),
                lastError: nil,
                metrics: metrics,
                accountStatus: parser.accountStatus(
                    from: snapshot,
                    subscriptionType: credential.subscriptionType,
                    rateLimitTier: nil
                )
            )
        } catch {
            logger.log(.error, "Response parse failed for '\(credential.accountLabel)': \(error)")
            return errorEntry(account: account, type: "parse_error", isActive: isActive, preservedMetrics: preserved)
        }
    }

    /// Resolves the account identity for a credential, preferring the real
    /// account email (so Claude Desktop and Claude TUI entries for the same
    /// person share an identity). Resolution is cached per account UUID. Falls
    /// back to the profile-derived label when the email cannot be fetched (no
    /// UUID, expired token, or profile endpoint failure).
    private func resolveAccount(credential: ClaudeDesktopCredential, tokenLikelyExpired: Bool) async -> AccountEmail {
        let fallback = AccountEmail(rawValue: credential.accountLabel)
        guard let uuid = credential.accountUuid else { return fallback }
        if let cached = emailCacheByUuid[uuid] { return cached }
        // A dead token cannot resolve a profile; keep the label until a live
        // token lets us resolve the real email on a later tick.
        guard !tokenLikelyExpired else { return fallback }
        guard let email = await profileResolver.resolveEmail(accessToken: credential.accessToken) else {
            return fallback
        }
        emailCacheByUuid[uuid] = email
        return email
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
