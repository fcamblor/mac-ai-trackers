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

    private let keychainServiceName: String
    private let processRunner: ProcessRunning
    private let logger: FileLogger

    public init(
        keychainServiceName: String = ClaudeCredentialLocator.defaultKeychainService,
        processRunner: ProcessRunning = FoundationProcessRunner(),
        logger: FileLogger = Loggers.claude
    ) {
        self.keychainServiceName = keychainServiceName
        self.processRunner = processRunner
        self.logger = logger
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

        return ClaudeCredentials(accessToken: token)
    }
}
