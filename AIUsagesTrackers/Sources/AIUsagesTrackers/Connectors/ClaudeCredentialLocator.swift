import Foundation

/// What `ClaudeCredentialLocator.locate()` produces — a Claude OAuth bearer
/// token resolved from the macOS Keychain entry written by the `claude` CLI.
public struct ClaudeCredentials: Sendable, Equatable {
    public let accessToken: String

    public init(accessToken: String) {
        self.accessToken = accessToken
    }
}

public enum ClaudeAuthError: Error, CustomStringConvertible {
    case keychainAccessDenied(serviceName: String, exitCode: Int32)
    case keychainEmpty(serviceName: String)
    case keychainTimeout(serviceName: String, timeoutSeconds: Int)
    case keychainParseFailed(serviceName: String, rawPreview: String)
    /// The entry was readable JSON but did not carry a `claudeAiOauth.accessToken`
    /// — typically the MCP plugin OAuth state entry that the `claude` CLI also
    /// writes under the same service. Kept distinct from `keychainParseFailed`
    /// so the locator can detect a stale pinned account and reset it.
    case missingOAuthBlock(serviceName: String, account: String?)
    case apiKeyOnlyUnsupported(serviceName: String)
    /// Access token from the keychain has passed its `expiresAt` timestamp.
    /// The user must re-run the `claude` CLI to refresh — the locator is
    /// read-only by contract and never invokes the OAuth refresh flow.
    case tokenExpired(serviceName: String, expiredAt: Date)

    public var description: String {
        switch self {
        case let .keychainAccessDenied(svc, code):
            "Keychain access denied for service '\(svc)' (exit \(code))"
        case let .keychainEmpty(svc):
            "Keychain item is empty for service '\(svc)'"
        case let .keychainTimeout(svc, secs):
            "Keychain access timed out after \(secs)s for service '\(svc)'"
        case let .keychainParseFailed(svc, preview):
            "Failed to parse keychain value for service '\(svc)' — preview: '\(preview.prefix(80))'"
        case let .missingOAuthBlock(svc, account):
            "Keychain entry for service '\(svc)' (account: \(account ?? "(none)")) has no `claudeAiOauth.accessToken`"
        case let .apiKeyOnlyUnsupported(svc):
            "Claude Code is authenticated with a standard API key in service '\(svc)'; usage reporting requires Claude Code OAuth credentials"
        case let .tokenExpired(svc, expiredAt):
            "OAuth access token for service '\(svc)' expired at \(expiredAt)"
        }
    }
}

/// Reads the Claude OAuth access token from the macOS Keychain entry
/// written by the `claude` CLI. Read-only by contract — never calls
/// `SecItemAdd`, `SecItemUpdate`, `SecItemDelete`; never invokes
/// `claude auth login`; never writes any vendor file.
///
/// Bootstrap contract: no `security` invocation made by this locator may
/// trigger a Keychain authorisation prompt the user hasn't already seen for
/// the runtime poll path. Attribute-only lookups (`security … -s …` without
/// `-w`/`-g`) are safe because they don't access the secret data. The
/// password fetch (`-w`) reuses the same ACL slot the user has already
/// approved for the connector poll, so no additional prompt is triggered.
public actor ClaudeCredentialLocator: CredentialLocator {
    public typealias Credentials = ClaudeCredentials

    public static let defaultKeychainService = "Claude Code-credentials"
    public static let apiKeyKeychainService = "Claude Code"
    /// Long enough for a cached keychain lookup; short enough to avoid
    /// stalling the poller.
    public static let keychainTimeoutSeconds = 10
    /// Treat the token as expired this many seconds before the actual
    /// `expiresAt` to avoid the race where we send a request just as the
    /// token flips invalid and burn a 401 we could have skipped.
    public static let expirySkewSeconds: TimeInterval = 60
    private static let securityItemNotFoundExitCode: Int32 = 44

    private let keychainServiceName: String
    private let processRunner: ProcessRunning
    private let logger: FileLogger
    private let clock: @Sendable () -> Date
    /// Resolved at every `locate()` call so a preference change in the Coding
    /// Assistants tab takes effect without restarting the app. `nil` keeps the
    /// historical "first match wins" behaviour of `security find-generic-password`.
    private let accountOverride: @Sendable () -> String?
    /// Called whenever the locator wants to mutate the persisted preference:
    /// a non-nil value pins a freshly-resolved account (auto-pin at first
    /// successful read), nil resets a stale pin (the previously-selected
    /// entry no longer carries `claudeAiOauth`, typically after a logout +
    /// re-login left an MCP entry in front).
    private let accountPersistor: @Sendable (String?) -> Void

    public init(
        keychainServiceName: String = ClaudeCredentialLocator.defaultKeychainService,
        processRunner: ProcessRunning = FoundationProcessRunner(),
        logger: FileLogger = Loggers.claude,
        clock: @escaping @Sendable () -> Date = { Date() },
        accountOverride: @escaping @Sendable () -> String? = { nil },
        accountPersistor: @escaping @Sendable (String?) -> Void = { _ in }
    ) {
        self.keychainServiceName = keychainServiceName
        self.processRunner = processRunner
        self.logger = logger
        self.clock = clock
        self.accountOverride = accountOverride
        self.accountPersistor = accountPersistor
    }

    public func locate() async throws -> ClaudeCredentials {
        try await locate(allowResetRetry: true)
    }

    private func locate(allowResetRetry: Bool) async throws -> ClaudeCredentials {
        let resolvedAccount = accountOverride()
        let effectiveAccount = try await resolveEffectiveAccount(explicit: resolvedAccount)

        let token: String
        do {
            token = try await readToken(account: effectiveAccount)
        } catch let error as ClaudeAuthError {
            // A pinned account that no longer resolves to a `claudeAiOauth`
            // entry is the recoverable "logout + re-login moved the MCP entry
            // in front" case. Reset the pin and re-run the lookup once with no
            // override so the next attempt can re-pin a different acct.
            if resolvedAccount != nil, allowResetRetry, shouldResetPinnedAccount(for: error) {
                logger.log(.warning, "Pinned Claude keychain account '\(resolvedAccount ?? "")' no longer carries claudeAiOauth — resetting and retrying without override")
                accountPersistor(nil)
                return try await locate(allowResetRetry: false)
            }
            throw error
        }

        return ClaudeCredentials(accessToken: token)
    }

    /// When an `accountOverride` is provided, we use it as-is. Otherwise we
    /// run an attribute-only `security` call to discover the `acct` of the
    /// first match — this is a no-prompt lookup (no `-w`, no `-g`) and lets us
    /// auto-pin a stable account on first successful read.
    private func resolveEffectiveAccount(explicit: String?) async throws -> String? {
        if let explicit, !explicit.isEmpty { return explicit }
        return try await readFirstAccountAttribute()
    }

    private func readFirstAccountAttribute() async throws -> String? {
        let result = try await processRunner.run(
            executablePath: "/usr/bin/security",
            arguments: ["find-generic-password", "-s", keychainServiceName],
            timeoutSeconds: Self.keychainTimeoutSeconds
        )
        if result.timedOut {
            throw ClaudeAuthError.keychainTimeout(serviceName: keychainServiceName, timeoutSeconds: Self.keychainTimeoutSeconds)
        }
        // Don't fail the whole locate() on attribute lookup errors — fall back
        // to the legacy "first match wins" behaviour by returning nil.
        guard result.terminationStatus == 0,
              let raw = String(data: result.stdout, encoding: .utf8) else {
            return nil
        }
        return Self.parseAccountAttribute(from: raw)
    }

    /// Parses lines like `    "acct"<blob>="juherr"` out of the `security`
    /// CLI's human-formatted attribute dump.
    static func parseAccountAttribute(from raw: String) -> String? {
        for line in raw.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("\"acct\"") else { continue }
            guard let equalsIndex = trimmed.firstIndex(of: "=") else { continue }
            let afterEquals = trimmed[trimmed.index(after: equalsIndex)...]
            let unquoted = afterEquals.trimmingCharacters(in: CharacterSet(charactersIn: "\""))
            // `0x` prefix indicates a hex-encoded blob (rare for acct, but be safe).
            if unquoted.hasPrefix("0x") { return nil }
            return unquoted.isEmpty ? nil : unquoted
        }
        return nil
    }

    private func readToken(account: String?) async throws -> String {
        let serviceName = keychainServiceName
        let timeoutSecs = Self.keychainTimeoutSeconds

        var arguments = ["find-generic-password", "-s", serviceName]
        if let account, !account.isEmpty {
            arguments.append(contentsOf: ["-a", account])
        }
        arguments.append("-w")

        let result = try await processRunner.run(
            executablePath: "/usr/bin/security",
            arguments: arguments,
            timeoutSeconds: timeoutSecs
        )
        if result.timedOut {
            throw ClaudeAuthError.keychainTimeout(serviceName: serviceName, timeoutSeconds: timeoutSecs)
        }
        guard result.terminationStatus == 0 else {
            if serviceName == Self.defaultKeychainService,
               try await hasStandardAPIKey(timeoutSeconds: timeoutSecs) {
                throw ClaudeAuthError.apiKeyOnlyUnsupported(serviceName: Self.apiKeyKeychainService)
            }
            throw ClaudeAuthError.keychainAccessDenied(serviceName: serviceName, exitCode: result.terminationStatus)
        }

        guard let raw = String(data: result.stdout, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty else {
            throw ClaudeAuthError.keychainEmpty(serviceName: serviceName)
        }

        guard let jsonData = raw.data(using: .utf8) else {
            throw ClaudeAuthError.keychainParseFailed(serviceName: serviceName, rawPreview: raw)
        }

        let parsed: [String: Any]
        do {
            parsed = try JSONSerialization.jsonObject(with: jsonData) as? [String: Any] ?? [:]
        } catch {
            throw ClaudeAuthError.keychainParseFailed(serviceName: serviceName, rawPreview: raw)
        }

        guard let oauth = parsed["claudeAiOauth"] as? [String: Any],
              let token = oauth["accessToken"] as? String,
              !token.isEmpty else {
            throw ClaudeAuthError.missingOAuthBlock(serviceName: serviceName, account: account)
        }

        // We made it past the JSON / claudeAiOauth gate: the account behind
        // this entry is a sound pin target even when the token is expired —
        // a CLI refresh will rotate the token in place under the same `acct`.
        if let account, !account.isEmpty {
            accountPersistor(account)
        }

        // expiresAt is a Unix millisecond timestamp written by the `claude` CLI
        // (Node.js convention — `Date.now()`). A missing or unparseable value
        // skips the local check: the API call still happens and a 401 will
        // surface as token_expired downstream.
        if let expiresAtRaw = oauth["expiresAt"], let expiryDate = Self.parseExpiresAt(expiresAtRaw) {
            let now = clock()
            if now.addingTimeInterval(Self.expirySkewSeconds) >= expiryDate {
                throw ClaudeAuthError.tokenExpired(serviceName: serviceName, expiredAt: expiryDate)
            }
        }

        return token
    }

    /// Errors that indicate the pinned `kSecAttrAccount` now points at an
    /// entry without a `claudeAiOauth` block (or no entry at all) and the
    /// preference should be reset so the next lookup can re-pin.
    private func shouldResetPinnedAccount(for error: ClaudeAuthError) -> Bool {
        switch error {
        case .missingOAuthBlock, .keychainEmpty, .keychainParseFailed:
            return true
        case let .keychainAccessDenied(_, exitCode):
            // Exit 44 is the `security` CLI's "item not found" path. Other
            // failures can be transient permission/keychain state and must not
            // erase an explicit user selection.
            return exitCode == Self.securityItemNotFoundExitCode
        case .tokenExpired, .apiKeyOnlyUnsupported, .keychainTimeout:
            return false
        }
    }

    private func hasStandardAPIKey(timeoutSeconds: Int) async throws -> Bool {
        let result = try await processRunner.run(
            executablePath: "/usr/bin/security",
            arguments: ["find-generic-password", "-s", Self.apiKeyKeychainService, "-w"],
            timeoutSeconds: timeoutSeconds
        )
        guard !result.timedOut, result.terminationStatus == 0,
              let raw = String(data: result.stdout, encoding: .utf8) else {
            return false
        }
        return raw.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("sk-ant-api")
    }

    /// Accepts `Double`, `Int`, or numeric `String` (millisecond epoch).
    /// Returns nil if the value is missing or in an unrecognized shape — the
    /// caller then skips the local expiry check rather than risking a false
    /// positive that would silence the connector.
    static func parseExpiresAt(_ raw: Any) -> Date? {
        let millis: Double
        switch raw {
        case let value as Double: millis = value
        case let value as Int: millis = Double(value)
        case let value as String:
            guard let parsed = Double(value) else { return nil }
            millis = parsed
        default: return nil
        }
        guard millis.isFinite, millis > 0 else { return nil }
        return Date(timeIntervalSince1970: millis / 1000)
    }
}
