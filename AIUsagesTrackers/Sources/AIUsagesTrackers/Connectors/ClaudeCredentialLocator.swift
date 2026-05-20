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

    private let keychainServiceName: String
    private let processRunner: ProcessRunning
    private let logger: FileLogger
    private let clock: @Sendable () -> Date

    public init(
        keychainServiceName: String = ClaudeCredentialLocator.defaultKeychainService,
        processRunner: ProcessRunning = FoundationProcessRunner(),
        logger: FileLogger = Loggers.claude,
        clock: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.keychainServiceName = keychainServiceName
        self.processRunner = processRunner
        self.logger = logger
        self.clock = clock
    }

    public func locate() async throws -> ClaudeCredentials {
        let serviceName = keychainServiceName
        let timeoutSecs = Self.keychainTimeoutSeconds
        let now = clock()

        var candidates: [(token: String, expiryDate: Date?)] = []
        var allLookupsFailed = true
        var lastFailedExitCode: Int32 = -1
        var lastRawPreview = ""

        // Try username-scoped entry first (matches the `claude` CLI convention:
        // `security find-generic-password -a "$USER" -s "..." -w`).
        // A second entry with the same service but a different account (often
        // `acct=unknown`) may hold only MCP plugin OAuth state and no `claudeAiOauth`.
        // The unscoped fallback covers older installs and reordered keychain entries.
        // Duplicates across both lookups are skipped by token value.
        let lookupArgSets: [[String]] = [
            ["find-generic-password", "-a", NSUserName(), "-s", serviceName, "-w"],
            ["find-generic-password", "-s", serviceName, "-w"],
        ]

        for args in lookupArgSets {
            let result = try await processRunner.run(
                executablePath: "/usr/bin/security",
                arguments: args,
                timeoutSeconds: timeoutSecs
            )
            if result.timedOut {
                throw ClaudeAuthError.keychainTimeout(serviceName: serviceName, timeoutSeconds: timeoutSecs)
            }
            guard result.terminationStatus == 0 else {
                lastFailedExitCode = result.terminationStatus
                continue
            }
            allLookupsFailed = false

            guard let raw = String(data: result.stdout, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
                  !raw.isEmpty else {
                continue
            }

            guard let jsonData = raw.data(using: .utf8) else {
                lastRawPreview = raw
                continue
            }

            let parsed: [String: Any]
            do {
                parsed = (try JSONSerialization.jsonObject(with: jsonData) as? [String: Any]) ?? [:]
            } catch {
                lastRawPreview = raw
                continue
            }

            guard let oauth = parsed["claudeAiOauth"] as? [String: Any],
                  let token = oauth["accessToken"] as? String,
                  !token.isEmpty else {
                lastRawPreview = raw
                continue
            }

            guard !candidates.contains(where: { $0.token == token }) else { continue }

            // expiresAt is a Unix millisecond timestamp written by the `claude` CLI
            // (Node.js convention — `Date.now()`). A missing or unparseable value
            // skips the local check: the API call still happens and a 401 will
            // surface as token_expired downstream.
            let expiryDate = oauth["expiresAt"].flatMap { Self.parseExpiresAt($0) }
            candidates.append((token: token, expiryDate: expiryDate))
        }

        let skewedNow = now.addingTimeInterval(Self.expirySkewSeconds)
        if let best = candidates.first(where: { $0.expiryDate == nil || skewedNow < $0.expiryDate! }) {
            return ClaudeCredentials(accessToken: best.token)
        }

        if let expired = candidates.first, let expiredAt = expired.expiryDate {
            throw ClaudeAuthError.tokenExpired(serviceName: serviceName, expiredAt: expiredAt)
        }

        if allLookupsFailed {
            if serviceName == Self.defaultKeychainService,
               try await hasStandardAPIKey(timeoutSeconds: timeoutSecs) {
                throw ClaudeAuthError.apiKeyOnlyUnsupported(serviceName: Self.apiKeyKeychainService)
            }
            throw ClaudeAuthError.keychainAccessDenied(serviceName: serviceName, exitCode: lastFailedExitCode)
        }

        if !lastRawPreview.isEmpty {
            throw ClaudeAuthError.keychainParseFailed(serviceName: serviceName, rawPreview: lastRawPreview)
        }

        throw ClaudeAuthError.keychainEmpty(serviceName: serviceName)
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
