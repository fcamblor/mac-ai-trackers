import Foundation

// MARK: - Credentials

public struct CopilotCredentials: Sendable, Equatable {
    public let accessToken: String
    /// The GitHub login this token belongs to (e.g. `"fcamblor"`). Wrapped in
    /// `AccountEmail` because the rest of the app keys accounts by that type;
    /// for Copilot the login string is the natural per-account identity since
    /// the `copilot_internal/user` endpoint exposes no email.
    public let login: AccountEmail
    public let tokenSource: TokenSource
    /// Whether this login is the currently-active `gh` account in `hosts.yml`.
    public let isActive: Bool

    public init(
        accessToken: String,
        login: AccountEmail,
        tokenSource: TokenSource,
        isActive: Bool = true
    ) {
        self.accessToken = accessToken
        self.login = login
        self.tokenSource = tokenSource
        self.isActive = isActive
    }
}

public enum TokenSource: String, Sendable, Equatable {
    case envVar = "env"
    case keychain
    case hostsFile = "hosts_file"
}

// MARK: - Protocol

public protocol CopilotCredentialLocating: CredentialLocator where Credentials == CopilotCredentials {
    /// Returns credentials for every GitHub login the locator can authenticate,
    /// plus the active login from `hosts.yml` (which may have no resolvable token).
    func locateAll() async throws -> (activeLogin: AccountEmail, credentials: [CopilotCredentials])
}

// MARK: - Errors

public enum CopilotCredentialLocatorError: Error, CustomStringConvertible {
    case notLoggedIn(searchedPaths: [String])
    case hostsFileReadFailed(path: String, underlying: Error)
    case hostsFileParseFailed(path: String, rawPreview: String)
    case noTokenAvailable(activeLogin: String)
    case keychainAccessDenied(exitCode: Int32)
    case keychainTimeout(timeoutSeconds: Int)
    case keychainParseFailed(rawPreview: String)

    public var description: String {
        switch self {
        case let .notLoggedIn(paths):
            "No active GitHub account — `gh auth login` required. Searched: \(paths.joined(separator: ", "))"
        case let .hostsFileReadFailed(path, underlying):
            "Failed to read gh hosts.yml at '\(path)': \(underlying)"
        case let .hostsFileParseFailed(path, preview):
            "Failed to parse gh hosts.yml at '\(path)' — preview: '\(preview.prefix(80))'"
        case let .noTokenAvailable(login):
            "No Copilot token available for '\(login)' — checked $GITHUB_TOKEN, gh keychain, hosts.yml"
        case let .keychainAccessDenied(code):
            "Keychain access denied for service 'gh:github.com' (exit \(code))"
        case let .keychainTimeout(secs):
            "Keychain access timed out after \(secs)s for service 'gh:github.com'"
        case let .keychainParseFailed(preview):
            "Failed to decode gh:github.com keychain value — preview: '\(preview.prefix(80))'"
        }
    }
}

// MARK: - Implementation

public actor CopilotCredentialLocator: CopilotCredentialLocating {
    public typealias Credentials = CopilotCredentials

    private static let keychainService = "gh:github.com"
    private static let keychainTimeoutSeconds = 10
    private static let goKeyringBase64Prefix = "go-keyring-base64:"
    private static let envVarName = "GITHUB_TOKEN"

    private let environment: [String: String]
    private let hostsFilePathOverride: String?
    private let fileManager: FileManager
    private let logger: FileLogger
    private let processRunner: ProcessRunning
    private let session: URLSession

    public init(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        hostsFilePathOverride: String? = nil,
        fileManager: FileManager = .default,
        logger: FileLogger = Loggers.copilot,
        processRunner: ProcessRunning = FoundationProcessRunner(),
        session: URLSession = .shared
    ) {
        self.environment = environment
        self.hostsFilePathOverride = hostsFilePathOverride
        self.fileManager = fileManager
        self.logger = logger
        self.processRunner = processRunner
        self.session = session
    }

    public func locate() async throws -> CopilotCredentials {
        let batch = try await locateAll()
        guard let active = batch.credentials.first(where: { $0.login == batch.activeLogin }) else {
            throw CopilotCredentialLocatorError.noTokenAvailable(activeLogin: batch.activeLogin.rawValue)
        }
        return active
    }

    public func locateAll() async throws -> (activeLogin: AccountEmail, credentials: [CopilotCredentials]) {
        let parsed = try resolveHostsConfig()

        guard let activeLoginString = parsed.config.activeLogin, !activeLoginString.isEmpty else {
            throw CopilotCredentialLocatorError.notLoggedIn(searchedPaths: parsed.searchedPaths)
        }
        let activeLogin = AccountEmail(rawValue: activeLoginString)

        let discovery = try await discoverLogins(from: parsed.config)
        var credentials: [CopilotCredentials] = []
        for login in discovery.logins {
            let isActive = login == activeLoginString
            guard let resolved = try await resolveToken(
                for: login,
                config: parsed.config,
                isActiveLogin: isActive,
                unscopedKeychainCredential: discovery.unscopedKeychainCredential
            ) else {
                continue
            }
            credentials.append(CopilotCredentials(
                accessToken: resolved.token,
                login: AccountEmail(rawValue: login),
                tokenSource: resolved.source,
                isActive: isActive
            ))
        }

        return (activeLogin, credentials)
    }

    /// Logins the locator will attempt to authenticate — union of `users:` entries,
    /// the active `user:` field, and the login owning the gh keychain token.
    public static func knownLogins(from config: HostsConfig) -> [String] {
        var logins = Set(config.registeredUserLogins)
        logins.formUnion(config.perUserTokens.keys)
        if let activeLogin = config.activeLogin, !activeLogin.isEmpty {
            logins.insert(activeLogin)
        }
        return logins.sorted()
    }

    private struct LoginDiscovery {
        let logins: [String]
        let unscopedKeychainCredential: (login: String, token: String)?
    }

    private func discoverLogins(from config: HostsConfig) async throws -> LoginDiscovery {
        var logins = Set(Self.knownLogins(from: config))
        var unscopedKeychainCredential: (login: String, token: String)?
        if let keychainToken = try await tryLoadKeychainToken(),
           let keychainLogin = await loginForToken(keychainToken) {
            logins.insert(keychainLogin)
            unscopedKeychainCredential = (keychainLogin, keychainToken)
        }
        return LoginDiscovery(
            logins: logins.sorted(),
            unscopedKeychainCredential: unscopedKeychainCredential
        )
    }

    private func loginForToken(_ token: String) async -> String? {
        var request = URLRequest(url: Self.githubUserURL)
        request.setValue("token \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = CopilotConstants.requestTimeoutSeconds

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            logger.log(.warning, "Failed to resolve GitHub login for token: \(error)")
            return nil
        }

        let httpCode = (response as? HTTPURLResponse)?.statusCode ?? -1
        guard httpCode == 200 else {
            logger.log(.debug, "GitHub /user returned HTTP \(httpCode) while resolving token login")
            return nil
        }

        do {
            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let login = json["login"] as? String,
                  !login.isEmpty else {
                return nil
            }
            return login
        } catch {
            logger.log(.debug, "GitHub /user JSON parse failed: \(error)")
            return nil
        }
    }

    private static let githubUserURL = URL(string: "https://api.github.com/user")! // known-valid literal

    private func resolveToken(
        for login: String,
        config: HostsConfig,
        isActiveLogin: Bool,
        unscopedKeychainCredential: (login: String, token: String)?
    ) async throws -> (token: String, source: TokenSource)? {
        if isActiveLogin,
           let envToken = environment[Self.envVarName],
           !envToken.isEmpty {
            return (envToken, .envVar)
        }

        if let perUserToken = config.perUserTokens[login] {
            return (perUserToken, .hostsFile)
        }

        if isActiveLogin, let hostLevelToken = config.hostLevelToken {
            return (hostLevelToken, .hostsFile)
        }

        if let keychainToken = try await tryLoadKeychainToken(for: login) {
            return (keychainToken, .keychain)
        }

        if let unscoped = unscopedKeychainCredential, unscoped.login == login {
            return (unscoped.token, .keychain)
        }

        return nil
    }

    // MARK: - hosts.yml resolution

    public struct HostsConfig: Sendable, Equatable {
        public let activeLogin: String?
        public let hostLevelToken: String?
        public let perUserTokens: [String: String]
        /// Every login listed under `users:` — with or without a stored oauth token.
        public let registeredUserLogins: [String]

        public init(
            activeLogin: String?,
            hostLevelToken: String?,
            perUserTokens: [String: String],
            registeredUserLogins: [String] = []
        ) {
            self.activeLogin = activeLogin
            self.hostLevelToken = hostLevelToken
            self.perUserTokens = perUserTokens
            self.registeredUserLogins = registeredUserLogins
        }

        public func tokenForLogin(_ login: String) -> String? {
            perUserTokens[login] ?? hostLevelToken
        }
    }

    private struct ResolvedHostsConfig {
        let config: HostsConfig
        let searchedPaths: [String]
    }

    private func resolveHostsConfig() throws -> ResolvedHostsConfig {
        let candidates = hostsFileCandidatePaths()
        for path in candidates where fileManager.fileExists(atPath: path) {
            let data: Data
            do {
                data = try Data(contentsOf: URL(fileURLWithPath: path))
            } catch {
                throw CopilotCredentialLocatorError.hostsFileReadFailed(path: path, underlying: error)
            }
            guard let text = String(data: data, encoding: .utf8) else {
                let preview = String(data: data.prefix(80), encoding: .utf8) ?? "<binary>"
                throw CopilotCredentialLocatorError.hostsFileParseFailed(path: path, rawPreview: preview)
            }
            logger.log(.debug, "Parsing gh hosts.yml at \(path)")
            return ResolvedHostsConfig(
                config: Self.parseHostsYAML(text),
                searchedPaths: candidates
            )
        }
        // No hosts file at all — caller will surface notLoggedIn.
        return ResolvedHostsConfig(
            config: HostsConfig(activeLogin: nil, hostLevelToken: nil, perUserTokens: [:]),
            searchedPaths: candidates
        )
    }

    private func hostsFileCandidatePaths() -> [String] {
        Self.candidatePaths(
            environment: environment,
            hostsFilePathOverride: hostsFilePathOverride,
            fileManager: fileManager
        )
    }

    public static func candidatePaths(
        environment: [String: String],
        hostsFilePathOverride: String?,
        fileManager: FileManager
    ) -> [String] {
        if let override = hostsFilePathOverride {
            return [override]
        }
        let home = fileManager.homeDirectoryForCurrentUser.path
        // Order mirrors gh CLI's own search: $GH_CONFIG_DIR → XDG → ~/.config/gh
        var paths: [String] = []
        if let ghConfigDir = environment["GH_CONFIG_DIR"], !ghConfigDir.isEmpty {
            paths.append("\(ghConfigDir)/hosts.yml")
        }
        if let xdg = environment["XDG_CONFIG_HOME"], !xdg.isEmpty {
            paths.append("\(xdg)/gh/hosts.yml")
        }
        paths.append("\(home)/.config/gh/hosts.yml")
        return paths
    }

    /// Minimal gh hosts.yml reader. We only need three fields under `github.com:`:
    /// the active `user:`, an optional host-level legacy `oauth_token:`, and the
    /// per-login `oauth_token:` entries inside `users:`. Avoiding a full YAML
    /// dependency keeps the build lean — gh writes this file with stable
    /// 4-space indentation, so a depth-tracking line scan is sufficient.
    static func parseHostsYAML(_ text: String) -> HostsConfig {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)

        // Locate the `github.com:` header.
        var index = 0
        while index < lines.count, lines[index].trimmingCharacters(in: .whitespaces) != "github.com:" {
            index += 1
        }
        guard index < lines.count else {
            return HostsConfig(activeLogin: nil, hostLevelToken: nil, perUserTokens: [:])
        }
        index += 1

        var activeLogin: String?
        var hostLevelToken: String?
        var perUserTokens: [String: String] = [:]
        var registeredUserLogins: Set<String> = []

        // `hostBlockIndent` is the indent of the first non-empty line under github.com:
        // — gh emits 4 spaces but we lock onto whatever the file uses.
        var hostBlockIndent: Int?
        var inUsersBlock = false
        var usersBlockIndent: Int?
        var currentUserLogin: String?

        while index < lines.count {
            defer { index += 1 }
            let line = lines[index]
            if line.trimmingCharacters(in: .whitespaces).isEmpty { continue }

            let indent = leadingSpaceCount(line)

            // Top-level (or another host) → end of github.com block
            if indent == 0 { break }

            if let hostIndent = hostBlockIndent {
                if indent < hostIndent { break }
            } else {
                hostBlockIndent = indent
            }

            // Are we still inside the users sub-block?
            if let usersIndent = usersBlockIndent, indent <= usersIndent {
                inUsersBlock = false
                usersBlockIndent = nil
                currentUserLogin = nil
            }

            let trimmed = line.trimmingCharacters(in: .whitespaces)

            if !inUsersBlock && indent == hostBlockIndent {
                if let value = stripPrefix("user:", from: trimmed) {
                    activeLogin = value
                } else if let value = stripPrefix("oauth_token:", from: trimmed) {
                    hostLevelToken = value
                } else if trimmed == "users:" {
                    inUsersBlock = true
                    usersBlockIndent = indent
                }
                continue
            }

            if inUsersBlock {
                // A user header looks like `<login>:` (no space-stripped value, no inline scalar).
                if trimmed.hasSuffix(":"), !trimmed.contains(" ") {
                    currentUserLogin = String(trimmed.dropLast())
                    registeredUserLogins.insert(currentUserLogin!)
                    continue
                }
                // A user-scoped key — currently we only care about oauth_token.
                if let user = currentUserLogin,
                   let value = stripPrefix("oauth_token:", from: trimmed) {
                    perUserTokens[user] = value
                }
            }
        }

        return HostsConfig(
            activeLogin: activeLogin,
            hostLevelToken: hostLevelToken,
            perUserTokens: perUserTokens,
            registeredUserLogins: registeredUserLogins.sorted()
        )
    }

    private static func leadingSpaceCount(_ line: String) -> Int {
        var count = 0
        for char in line {
            if char == " " { count += 1 }
            else if char == "\t" { count += 4 }
            else { break }
        }
        return count
    }

    private static func stripPrefix(_ prefix: String, from line: String) -> String? {
        guard line.hasPrefix(prefix) else { return nil }
        let value = line.dropFirst(prefix.count).trimmingCharacters(in: .whitespaces)
        return value.isEmpty ? nil : value
    }

    // MARK: - Keychain

    /// Reads the gh CLI token from the macOS keychain. When `login` is set, gh's
    /// per-account item is queried (`-a <login>`); otherwise the unscoped lookup
    /// is used (returns an arbitrary stored account). Returns `nil` if the entry
    /// is absent, throws for transport failures (timeout, denied).
    private func tryLoadKeychainToken(for login: String? = nil) async throws -> String? {
        var arguments = ["find-generic-password", "-s", Self.keychainService]
        if let login, !login.isEmpty {
            arguments.append(contentsOf: ["-a", login])
        }
        arguments.append("-w")

        let result = try await processRunner.run(
            executablePath: "/usr/bin/security",
            arguments: arguments,
            timeoutSeconds: Self.keychainTimeoutSeconds
        )
        if result.timedOut {
            throw CopilotCredentialLocatorError.keychainTimeout(timeoutSeconds: Self.keychainTimeoutSeconds)
        }

        // Exit 44 = item not found — propagate as "no keychain token", let cascade continue.
        if result.terminationStatus == 44 {
            return nil
        }
        if result.terminationStatus != 0 {
            throw CopilotCredentialLocatorError.keychainAccessDenied(exitCode: result.terminationStatus)
        }

        var rawString = String(data: result.stdout, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if rawString.isEmpty { return nil }

        // Some gh versions hex-encode non-ASCII payloads; CodexAuth uses the same trick.
        if rawString.hasPrefix("0x"), let decoded = Self.decodeHexUtf8(rawString) {
            rawString = decoded
        }

        // gh uses go-keyring on Linux — strips this prefix and base64-decodes the body.
        // The Mac path normally writes plain text, but tolerating the prefix is cheap.
        if rawString.hasPrefix(Self.goKeyringBase64Prefix) {
            let body = String(rawString.dropFirst(Self.goKeyringBase64Prefix.count))
            guard let data = Data(base64Encoded: body),
                  let decoded = String(data: data, encoding: .utf8) else {
                throw CopilotCredentialLocatorError.keychainParseFailed(rawPreview: rawString)
            }
            return decoded.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        return rawString
    }

    private static func decodeHexUtf8(_ hex: String) -> String? {
        let body = String(hex.dropFirst(2))
        guard body.count % 2 == 0 else { return nil }
        var bytes: [UInt8] = []
        var index = body.startIndex
        while index < body.endIndex {
            let nextIndex = body.index(index, offsetBy: 2)
            guard let byte = UInt8(body[index..<nextIndex], radix: 16) else { return nil }
            bytes.append(byte)
            index = nextIndex
        }
        return String(bytes: bytes, encoding: .utf8)
    }
}
