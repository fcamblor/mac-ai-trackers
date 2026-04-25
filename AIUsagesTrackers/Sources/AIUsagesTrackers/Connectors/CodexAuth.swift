import Foundation

// MARK: - Credentials

public struct CodexCredentials: Sendable, Equatable {
    public let accessToken: String
    public let accountId: AccountId
    public let accountEmail: AccountEmail?
    /// Parsed from `last_refresh` in auth.json; nil when the field is absent or unparseable.
    public let lastRefreshedAt: Date?

    public init(
        accessToken: String,
        accountId: AccountId,
        accountEmail: AccountEmail? = nil,
        lastRefreshedAt: Date? = nil
    ) {
        self.accessToken = accessToken
        self.accountId = accountId
        self.accountEmail = accountEmail
        self.lastRefreshedAt = lastRefreshedAt
    }

    public init(
        accessToken: String,
        accountId: String,
        accountEmail: AccountEmail? = nil,
        lastRefreshedAt: Date? = nil
    ) {
        self.init(
            accessToken: accessToken,
            accountId: AccountId(rawValue: accountId),
            accountEmail: accountEmail,
            lastRefreshedAt: lastRefreshedAt
        )
    }
}

// MARK: - Protocol

public protocol CodexAuthProviding: Sendable {
    func load() async throws -> CodexCredentials
}

// MARK: - Error

public enum CodexAuthError: Error, CustomStringConvertible {
    case noAuthFileFound(searchedPaths: [String])
    case readFailed(path: String, underlying: Error)
    case parseFailed(path: String, rawPreview: String)
    case missingAccountId(path: String)
    case keychainAccessDenied(exitCode: Int32)
    case keychainEmpty
    case keychainTimeout(timeoutSeconds: Int)
    case keychainParseFailed(rawPreview: String)

    public var description: String {
        switch self {
        case let .noAuthFileFound(paths):
            "No Codex auth file found — searched: \(paths.joined(separator: ", "))"
        case let .readFailed(path, underlying):
            "Failed to read Codex auth file at '\(path)': \(underlying)"
        case let .parseFailed(path, preview):
            "Failed to parse Codex auth JSON at '\(path)' — preview: '\(preview.prefix(80))'"
        case let .missingAccountId(path):
            "Codex auth at '\(path)' has no tokens.account_id — cannot identify account"
        case let .keychainAccessDenied(code):
            "Keychain access denied for service 'Codex Auth' (exit \(code))"
        case .keychainEmpty:
            "Keychain item is empty for service 'Codex Auth'"
        case let .keychainTimeout(secs):
            "Keychain access timed out after \(secs)s for service 'Codex Auth'"
        case let .keychainParseFailed(preview):
            "Failed to parse Codex Auth keychain value — preview: '\(preview.prefix(80))'"
        }
    }
}

// MARK: - Implementation

public actor CodexAuth: CodexAuthProviding {
    private static let keychainService = "Codex Auth"
    private static let keychainTimeoutSeconds = 10

    private let codexHomePath: String?
    private let fileManager: FileManager
    private let logger: FileLogger
    private let processRunner: ProcessRunning

    // Actor-isolated; safe without nonisolated(unsafe)
    private let isoFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    public init(
        codexHomePath: String? = nil,
        fileManager: FileManager = .default,
        logger: FileLogger = Loggers.codex,
        processRunner: ProcessRunning = FoundationProcessRunner()
    ) {
        self.codexHomePath = codexHomePath
        self.fileManager = fileManager
        self.logger = logger
        self.processRunner = processRunner
    }

    public func load() async throws -> CodexCredentials {
        let home = fileManager.homeDirectoryForCurrentUser.path

        // Build candidate paths in cascade order
        var candidates: [String] = []
        if let codexHome = codexHomePath ?? ProcessInfo.processInfo.environment["CODEX_HOME"] {
            candidates.append("\(codexHome)/auth.json")
        }
        candidates.append("\(home)/.config/codex/auth.json")
        candidates.append("\(home)/.codex/auth.json")

        for path in candidates {
            guard fileManager.fileExists(atPath: path) else { continue }
            logger.log(.debug, "Loading Codex auth from \(path)")
            return try parseAuthFile(at: path)
        }

        // Keychain fallback
        logger.log(.debug, "No auth.json found — falling back to Keychain '\(Self.keychainService)'")
        return try await loadFromKeychain()
    }

    // MARK: - File parsing

    private func parseAuthFile(at path: String) throws -> CodexCredentials {
        let data: Data
        do {
            data = try Data(contentsOf: URL(fileURLWithPath: path))
        } catch {
            throw CodexAuthError.readFailed(path: path, underlying: error)
        }

        let jsonObject: Any
        do {
            jsonObject = try JSONSerialization.jsonObject(with: data)
        } catch {
            let preview = String(data: data.prefix(80), encoding: .utf8) ?? "<binary>"
            throw CodexAuthError.parseFailed(path: path, rawPreview: preview)
        }
        guard let json = jsonObject as? [String: Any] else {
            let preview = String(data: data.prefix(80), encoding: .utf8) ?? "<binary>"
            throw CodexAuthError.parseFailed(path: path, rawPreview: preview)
        }

        let tokens = json["tokens"] as? [String: Any]
        guard let accessToken = tokens?["access_token"] as? String, !accessToken.isEmpty else {
            // Tolerate OPENAI_API_KEY-only auth files: no tokens dict means no account_id either
            let preview = String(data: data.prefix(80), encoding: .utf8) ?? "<binary>"
            throw CodexAuthError.parseFailed(path: path, rawPreview: preview)
        }

        guard let accountId = tokens?["account_id"] as? String, !accountId.isEmpty else {
            throw CodexAuthError.missingAccountId(path: path)
        }

        let lastRefreshedAt: Date?
        if let raw = json["last_refresh"] as? String {
            lastRefreshedAt = isoFormatter.date(from: raw)
        } else {
            lastRefreshedAt = nil
        }

        return CodexCredentials(
            accessToken: accessToken,
            accountId: AccountId(rawValue: accountId),
            accountEmail: extractAccountEmail(from: tokens),
            lastRefreshedAt: lastRefreshedAt
        )
    }

    // MARK: - Keychain

    private func loadFromKeychain() async throws -> CodexCredentials {
        let serviceName = Self.keychainService
        let timeoutSecs = Self.keychainTimeoutSeconds
        let result = try await processRunner.run(
            executablePath: "/usr/bin/security",
            arguments: ["find-generic-password", "-s", serviceName, "-w"],
            timeoutSeconds: timeoutSecs
        )
        if result.timedOut {
            throw CodexAuthError.keychainTimeout(timeoutSeconds: timeoutSecs)
        }
        guard result.terminationStatus == 0 else {
            throw CodexAuthError.keychainAccessDenied(exitCode: result.terminationStatus)
        }

        var rawString = String(data: result.stdout, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if rawString.isEmpty {
            throw CodexAuthError.keychainEmpty
        }

        // Keychain may hex-encode the value with a leading "0x" prefix
        if rawString.hasPrefix("0x"), let decoded = Self.decodeHexUtf8(rawString) {
            rawString = decoded
        }

        guard let jsonData = rawString.data(using: .utf8) else {
            throw CodexAuthError.keychainParseFailed(rawPreview: rawString)
        }
        let jsonObject: Any
        do {
            jsonObject = try JSONSerialization.jsonObject(with: jsonData)
        } catch {
            throw CodexAuthError.keychainParseFailed(rawPreview: rawString)
        }
        guard let json = jsonObject as? [String: Any],
              let tokens = json["tokens"] as? [String: Any],
              let accessToken = tokens["access_token"] as? String, !accessToken.isEmpty,
              let accountId = tokens["account_id"] as? String, !accountId.isEmpty else {
            throw CodexAuthError.keychainParseFailed(rawPreview: rawString)
        }

        let lastRefreshedAt: Date?
        if let raw = json["last_refresh"] as? String {
            lastRefreshedAt = isoFormatter.date(from: raw)
        } else {
            lastRefreshedAt = nil
        }

        return CodexCredentials(
            accessToken: accessToken,
            accountId: AccountId(rawValue: accountId),
            accountEmail: extractAccountEmail(from: tokens),
            lastRefreshedAt: lastRefreshedAt
        )
    }

    private static func decodeHexUtf8(_ hex: String) -> String? {
        let hexBody = String(hex.dropFirst(2)) // drop "0x"
        guard hexBody.count % 2 == 0 else { return nil }
        var bytes: [UInt8] = []
        var index = hexBody.startIndex
        while index < hexBody.endIndex {
            let nextIndex = hexBody.index(index, offsetBy: 2)
            guard let byte = UInt8(hexBody[index..<nextIndex], radix: 16) else { return nil }
            bytes.append(byte)
            index = nextIndex
        }
        return String(bytes: bytes, encoding: .utf8)
    }

    private func extractAccountEmail(from tokens: [String: Any]?) -> AccountEmail? {
        guard let tokens else { return nil }
        return extractAccountEmail(fromJWT: tokens["id_token"] as? String)
            ?? extractAccountEmail(fromJWT: tokens["access_token"] as? String)
    }

    private func extractAccountEmail(fromJWT token: String?) -> AccountEmail? {
        guard let claims = Self.jwtClaims(from: token) else { return nil }
        return normalizedEmail(claims["email"] as? String)
            ?? normalizedEmail(claims["https://api.openai.com/profile.email"] as? String)
    }

    private func normalizedEmail(_ rawValue: String?) -> AccountEmail? {
        guard let rawValue else { return nil }
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return AccountEmail(rawValue: trimmed)
    }

    private static func jwtClaims(from token: String?) -> [String: Any]? {
        guard let token else { return nil }
        let segments = token.split(separator: ".", omittingEmptySubsequences: false)
        guard segments.count >= 2,
              let payload = base64URLDecode(String(segments[1])),
              let object = try? JSONSerialization.jsonObject(with: payload),
              let claims = object as? [String: Any] else {
            return nil
        }
        return claims
    }

    private static func base64URLDecode(_ input: String) -> Data? {
        let base64 = input
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let padding = (4 - (base64.count % 4)) % 4
        return Data(base64Encoded: base64 + String(repeating: "=", count: padding))
    }
}
