import Foundation

public struct AntigravityCredentials: Sendable, Equatable {
    public let accessToken: String
    public let expiresAt: Date

    public init(accessToken: String, expiresAt: Date) {
        self.accessToken = accessToken
        self.expiresAt = expiresAt
    }
}

public enum AntigravityAuthError: Error, CustomStringConvertible {
    case keychainAccessDenied(serviceName: String, exitCode: Int32)
    case keychainEmpty(serviceName: String)
    case keychainTimeout(serviceName: String, timeoutSeconds: Int)
    case keychainParseFailed(serviceName: String, rawPreview: String)
    case missingExpiresAt(serviceName: String)
    case invalidExpiresAtFormat(serviceName: String, rawValue: String)
    case tokenExpired(serviceName: String, expiredAt: Date)
    case bootstrapFailed(reason: String)

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
        case let .missingExpiresAt(svc):
            "Keychain entry for service '\(svc)' is missing expiresAt field"
        case let .invalidExpiresAtFormat(svc, raw):
            "Keychain entry for service '\(svc)' has invalid expiresAt format: '\(raw)'"
        case let .tokenExpired(svc, expiredAt):
            "OAuth access token for service '\(svc)' expired at \(expiredAt)"
        case let .bootstrapFailed(reason):
            "Antigravity bootstrap failed: \(reason)"
        }
    }
}

/// Reads the Antigravity OAuth access token from the macOS Keychain entry
/// written by the `antigravity` CLI or from the ANTIGRAVITY_API_KEY environment variable.
/// Read-only by contract — never calls SecItemAdd, SecItemUpdate, or SecItemDelete.
///
/// Bootstrap contract: no Keychain access made by this locator triggers an
/// authorisation prompt beyond the one the user has already approved for the
/// steady-state vendor poll.
public actor AntigravityCredentialLocator: CredentialLocator {
    public typealias Credentials = AntigravityCredentials

    public static let defaultKeychainService = "gemini"
    public static let keychainAccount = "antigravity"
    public static let keychainTimeoutSeconds = 10
    public static let expirySkewSeconds: TimeInterval = 60
    private static let securityItemNotFoundExitCode: Int32 = 44

    private let keychainServiceName: String
    private let processRunner: ProcessRunning
    private let environment: [String: String]
    private let logger: FileLogger
    private let clock: @Sendable () -> Date

    public init(
        keychainServiceName: String = AntigravityCredentialLocator.defaultKeychainService,
        processRunner: ProcessRunning = FoundationProcessRunner(),
        environment: [String: String] = ProcessInfo.processInfo.environment,
        logger: FileLogger = Loggers.antigravity,
        clock: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.keychainServiceName = keychainServiceName
        self.processRunner = processRunner
        self.environment = environment
        self.logger = logger
        self.clock = clock
    }

    public func locate() async throws -> AntigravityCredentials {
        logger.log(.debug, "AntigravityCredentialLocator.locate() starting")

        let now = clock()
        let now_rfc3339 = ISO8601DateFormatter().string(from: now)

        if let envToken = environment["ANTIGRAVITY_API_KEY"] {
            logger.log(.debug, "Found ANTIGRAVITY_API_KEY in environment")
            return AntigravityCredentials(
                accessToken: envToken,
                expiresAt: now.addingTimeInterval(3600)
            )
        }

        let keychainQuery = [
            "find-generic-password",
            "-s", keychainServiceName,
            "-a", Self.keychainAccount
        ]

        let attributeResult = try await processRunner.run(
            executablePath: "/usr/bin/security",
            arguments: keychainQuery,
            timeoutSeconds: Self.keychainTimeoutSeconds
        )

        guard attributeResult.terminationStatus == 0 || attributeResult.terminationStatus == Self.securityItemNotFoundExitCode
        else {
            throw AntigravityAuthError.keychainAccessDenied(
                serviceName: keychainServiceName,
                exitCode: attributeResult.terminationStatus
            )
        }

        guard attributeResult.terminationStatus == 0 else {
            logger.log(.debug, "No keychain entry found at [\(keychainServiceName):\(Self.keychainAccount)]")
            throw AntigravityAuthError.bootstrapFailed(reason: "No stored credentials (run `antigravity auth` first)")
        }

        let passwordQuery = keychainQuery + ["-w"]
        let passwordResult = try await processRunner.run(
            executablePath: "/usr/bin/security",
            arguments: passwordQuery,
            timeoutSeconds: Self.keychainTimeoutSeconds
        )

        guard passwordResult.terminationStatus == 0 else {
            throw AntigravityAuthError.keychainAccessDenied(
                serviceName: keychainServiceName,
                exitCode: passwordResult.terminationStatus
            )
        }

        let passwordStr = String(data: passwordResult.stdout, encoding: String.Encoding.utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !passwordStr.isEmpty else {
            throw AntigravityAuthError.keychainEmpty(serviceName: keychainServiceName)
        }

        // The `antigravity` CLI uses the Go `keyring` library which wraps values
        // with a `go-keyring-base64:` prefix before storing. Strip + decode.
        let jsonData: Data
        if passwordStr.hasPrefix(Self.goKeyringPrefix) {
            let base64Part = String(passwordStr.dropFirst(Self.goKeyringPrefix.count))
            guard let decoded = Data(base64Encoded: base64Part) else {
                let preview = String(passwordStr.prefix(100))
                throw AntigravityAuthError.keychainParseFailed(serviceName: keychainServiceName, rawPreview: preview)
            }
            jsonData = decoded
        } else {
            guard let direct = passwordStr.data(using: .utf8) else {
                throw AntigravityAuthError.keychainParseFailed(serviceName: keychainServiceName, rawPreview: String(passwordStr.prefix(100)))
            }
            jsonData = direct
        }

        guard let json = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any],
              let tokenDict = json["token"] as? [String: Any]
        else {
            let preview = String(passwordStr.prefix(100))
            throw AntigravityAuthError.keychainParseFailed(serviceName: keychainServiceName, rawPreview: preview)
        }

        guard let accessToken = tokenDict["access_token"] as? String, !accessToken.isEmpty else {
            let preview = String(passwordStr.prefix(100))
            throw AntigravityAuthError.keychainParseFailed(serviceName: keychainServiceName, rawPreview: preview)
        }

        guard let expiryStr = tokenDict["expiry"] as? String else {
            throw AntigravityAuthError.missingExpiresAt(serviceName: keychainServiceName)
        }

        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        var parsedExpiry = formatter.date(from: expiryStr)
        if parsedExpiry == nil {
            // Fallback for values without sub-second precision
            let plainFormatter = ISO8601DateFormatter()
            plainFormatter.formatOptions = [.withInternetDateTime]
            parsedExpiry = plainFormatter.date(from: expiryStr)
        }
        guard let expiresAt = parsedExpiry else {
            throw AntigravityAuthError.invalidExpiresAtFormat(serviceName: keychainServiceName, rawValue: expiryStr)
        }

        logger.log(.debug, "AntigravityCredentialLocator.locate() succeeded, token expires at \(expiresAt)")

        return AntigravityCredentials(accessToken: accessToken, expiresAt: expiresAt)
    }

    private static let goKeyringPrefix = "go-keyring-base64:"
}
