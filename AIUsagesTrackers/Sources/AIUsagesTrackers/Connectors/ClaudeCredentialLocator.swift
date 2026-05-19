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

        let result = try await processRunner.run(
            executablePath: "/usr/bin/security",
            arguments: ["find-generic-password", "-s", serviceName, "-w"],
            timeoutSeconds: timeoutSecs
        )
        if result.timedOut {
            throw ClaudeAuthError.keychainTimeout(serviceName: serviceName, timeoutSeconds: timeoutSecs)
        }
        guard result.terminationStatus == 0 else {
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
            throw ClaudeAuthError.keychainParseFailed(serviceName: serviceName, rawPreview: raw)
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

        return ClaudeCredentials(accessToken: token)
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
