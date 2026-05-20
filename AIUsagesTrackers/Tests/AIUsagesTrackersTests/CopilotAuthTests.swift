import Foundation
import Testing
@testable import AIUsagesTrackersLib

// swiftlint:disable:next w4_unchecked_sendable — URLProtocol subclass; static state accessed only from serialized suite
final class CopilotAuthMockURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var loginByToken: [String: String] = [:]

    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.absoluteString == "https://api.github.com/user"
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let auth = request.value(forHTTPHeaderField: "Authorization") ?? ""
        let token = auth.replacingOccurrences(of: "token ", with: "")
        guard let login = Self.loginByToken[token] else {
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 401,
                httpVersion: nil,
                headerFields: nil
            )!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocolDidFinishLoading(self)
            return
        }
        let data = (try? JSONSerialization.data(withJSONObject: ["login": login])) ?? Data()
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: 200,
            httpVersion: nil,
            headerFields: nil
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

@Suite("CopilotAuth", .serialized)
struct CopilotAuthTests {
    private struct MockProcessRunner: ProcessRunning {
        let tokenByAccount: [String: String]
        let genericToken: String?
        let timedOut: Bool
        let failureExitCode: Int32?

        init(
            tokenByAccount: [String: String] = [:],
            genericToken: String? = nil,
            timedOut: Bool = false,
            failureExitCode: Int32? = nil
        ) {
            self.tokenByAccount = tokenByAccount
            self.genericToken = genericToken
            self.timedOut = timedOut
            self.failureExitCode = failureExitCode
        }

        func run(executablePath: String, arguments: [String], timeoutSeconds: Int) async throws -> ProcessExecutionResult {
            if timedOut {
                return ProcessExecutionResult(stdout: Data(), terminationStatus: 15, timedOut: true)
            }
            if let accountIndex = arguments.firstIndex(of: "-a"), accountIndex + 1 < arguments.count {
                let account = arguments[accountIndex + 1]
                if let token = tokenByAccount[account] {
                    return ProcessExecutionResult(stdout: Data(token.utf8), terminationStatus: 0, timedOut: false)
                }
                return ProcessExecutionResult(stdout: Data(), terminationStatus: 44, timedOut: false)
            }
            if let genericToken {
                return ProcessExecutionResult(stdout: Data(genericToken.utf8), terminationStatus: 0, timedOut: false)
            }
            if let failureExitCode {
                return ProcessExecutionResult(stdout: Data(), terminationStatus: failureExitCode, timedOut: false)
            }
            return ProcessExecutionResult(stdout: Data(), terminationStatus: 44, timedOut: false)
        }
    }

    private final class EmptyFileManager: FileManager, @unchecked Sendable {
        let home: URL

        init(home: URL) {
            self.home = home
            super.init()
        }

        override var homeDirectoryForCurrentUser: URL { home }
        override func fileExists(atPath path: String) -> Bool { false }
    }

    // MARK: - Helpers

    private func makeTempDir() throws -> String {
        let dir = NSTemporaryDirectory() + "ai-tracker-copilot-auth-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        return dir
    }

    private func writeHostsYAML(_ content: String, in dir: String) throws -> String {
        let path = "\(dir)/hosts.yml"
        try content.write(toFile: path, atomically: true, encoding: .utf8)
        return path
    }

    private func mockSession() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [CopilotAuthMockURLProtocol.self]
        return URLSession(configuration: config)
    }

    private func makeAuth(
        hostsPath: String? = nil,
        environment: [String: String] = [:],
        keychainRunner: MockProcessRunner? = nil,
        loginByToken: [String: String] = [:]
    ) throws -> CopilotCredentialLocator {
        let dir = try makeTempDir()
        let logger = FileLogger(filePath: "\(dir)/test.log", minLevel: .debug)
        let runner = keychainRunner ?? MockProcessRunner()
        CopilotAuthMockURLProtocol.loginByToken = loginByToken
        return CopilotCredentialLocator(
            environment: environment,
            hostsFilePathOverride: hostsPath,
            fileManager: .default,
            logger: logger,
            processRunner: runner,
            session: mockSession()
        )
    }

    // MARK: - hosts.yml parsing

    @Test("parseHostsYAML extracts active user from minimal Mac config")
    func parsesMinimalMacConfig() {
        let yaml = """
        github.com:
            git_protocol: ssh
            users:
                fcamblor:
            user: fcamblor
        """
        let config = CopilotCredentialLocator.parseHostsYAML(yaml)
        #expect(config.activeLogin == "fcamblor")
        #expect(config.hostLevelToken == nil)
        #expect(config.perUserTokens.isEmpty)
    }

    @Test("parseHostsYAML extracts host-level oauth_token (legacy single-user)")
    func parsesLegacyHostLevelToken() {
        let yaml = """
        github.com:
            user: alice
            oauth_token: gho_legacy_token
            git_protocol: https
        """
        let config = CopilotCredentialLocator.parseHostsYAML(yaml)
        #expect(config.activeLogin == "alice")
        #expect(config.hostLevelToken == "gho_legacy_token")
        #expect(config.tokenForLogin("alice") == "gho_legacy_token")
    }

    @Test("parseHostsYAML extracts per-user oauth_tokens for multi-user config")
    func parsesMultiUserTokens() {
        let yaml = """
        github.com:
            git_protocol: https
            users:
                alice:
                    oauth_token: gho_alice_token
                bob:
                    oauth_token: gho_bob_token
            user: bob
            oauth_token: gho_bob_token
        """
        let config = CopilotCredentialLocator.parseHostsYAML(yaml)
        #expect(config.activeLogin == "bob")
        #expect(config.perUserTokens["alice"] == "gho_alice_token")
        #expect(config.perUserTokens["bob"] == "gho_bob_token")
        #expect(config.tokenForLogin("alice") == "gho_alice_token")
        #expect(CopilotCredentialLocator.knownLogins(from: config) == ["alice", "bob"])
    }

    @Test("parseHostsYAML returns empty config when github.com block is absent")
    func parsesAbsentBlock() {
        let yaml = """
        gitlab.com:
            user: someone
        """
        let config = CopilotCredentialLocator.parseHostsYAML(yaml)
        #expect(config.activeLogin == nil)
    }

    @Test("parseHostsYAML stops at the next top-level host")
    func stopsAtNextHost() {
        let yaml = """
        github.com:
            user: alice
        ghe.example.com:
            user: bob
            oauth_token: enterprise_token
        """
        let config = CopilotCredentialLocator.parseHostsYAML(yaml)
        #expect(config.activeLogin == "alice")
        #expect(config.hostLevelToken == nil)
    }

    // MARK: - load() — token cascade

    @Test("load() prefers GITHUB_TOKEN env var over keychain and hosts file")
    func loadsFromEnvVar() async throws {
        let dir = try makeTempDir()
        let hostsPath = try writeHostsYAML("""
        github.com:
            user: alice
            oauth_token: hosts_token
        """, in: dir)
        let auth = try makeAuth(
            hostsPath: hostsPath,
            environment: ["GITHUB_TOKEN": "env_token"]
        )

        let credentials = try await auth.locate()
        #expect(credentials.accessToken == "env_token")
        #expect(credentials.tokenSource == .envVar)
        #expect(credentials.login.rawValue == "alice")
    }

    @Test("load() falls back to keychain when env var is unset")
    func loadsFromKeychain() async throws {
        let dir = try makeTempDir()
        let hostsPath = try writeHostsYAML("""
        github.com:
            user: bob
            users:
                bob:
        """, in: dir)
        let auth = try makeAuth(
            hostsPath: hostsPath,
            keychainRunner: MockProcessRunner(tokenByAccount: ["bob": "kc_token"]),
            loginByToken: ["kc_token": "bob"]
        )

        let credentials = try await auth.locate()
        #expect(credentials.accessToken == "kc_token")
        #expect(credentials.tokenSource == .keychain)
        #expect(credentials.login.rawValue == "bob")
    }

    @Test("load() decodes go-keyring-base64 prefix from keychain output")
    func decodesGoKeyringBase64() async throws {
        let dir = try makeTempDir()
        let hostsPath = try writeHostsYAML("""
        github.com:
            user: carol
        """, in: dir)
        let realToken = "gho_real_token"
        let encoded = "go-keyring-base64:" + Data(realToken.utf8).base64EncodedString()
        let auth = try makeAuth(
            hostsPath: hostsPath,
            keychainRunner: MockProcessRunner(tokenByAccount: ["carol": encoded]),
            loginByToken: [realToken: "carol"]
        )

        let credentials = try await auth.locate()
        #expect(credentials.accessToken == realToken)
        #expect(credentials.tokenSource == .keychain)
    }

    @Test("load() falls back to hosts.yml oauth_token when keychain is empty")
    func loadsFromHostsFile() async throws {
        let dir = try makeTempDir()
        let hostsPath = try writeHostsYAML("""
        github.com:
            user: dave
            users:
                dave:
                    oauth_token: hosts_only_token
        """, in: dir)
        let auth = try makeAuth(
            hostsPath: hostsPath,
            keychainRunner: MockProcessRunner(failureExitCode: 44)
        )

        let credentials = try await auth.locate()
        #expect(credentials.accessToken == "hosts_only_token")
        #expect(credentials.tokenSource == .hostsFile)
    }

    @Test("load() throws notLoggedIn when no active user in hosts.yml")
    func throwsNotLoggedInWhenNoUser() async throws {
        let dir = try makeTempDir()
        let hostsPath = try writeHostsYAML("""
        github.com:
            git_protocol: ssh
        """, in: dir)
        let auth = try makeAuth(hostsPath: hostsPath)

        await #expect(throws: CopilotCredentialLocatorError.self) {
            try await auth.locate()
        }
    }

    @Test("load() throws noTokenAvailable when login is set but no token cascades match")
    func throwsNoTokenWhenAllSourcesEmpty() async throws {
        let dir = try makeTempDir()
        let hostsPath = try writeHostsYAML("""
        github.com:
            user: eve
        """, in: dir)
        let auth = try makeAuth(
            hostsPath: hostsPath,
            keychainRunner: MockProcessRunner(failureExitCode: 44)
        )

        do {
            _ = try await auth.locate()
            Issue.record("Expected noTokenAvailable, but load succeeded")
        } catch let error as CopilotCredentialLocatorError {
            if case .noTokenAvailable(let login) = error {
                #expect(login == "eve")
            } else {
                Issue.record("Expected noTokenAvailable, got \(error)")
            }
        }
    }

    @Test("load() throws keychainTimeout when security command times out")
    func throwsKeychainTimeout() async throws {
        let dir = try makeTempDir()
        let hostsPath = try writeHostsYAML("""
        github.com:
            user: frank
        """, in: dir)
        let auth = try makeAuth(
            hostsPath: hostsPath,
            keychainRunner: MockProcessRunner(timedOut: true)
        )

        await #expect(throws: CopilotCredentialLocatorError.self) {
            try await auth.locate()
        }
    }

    @Test("locateAll() returns per-user tokens for every login in hosts.yml")
    func locateAllReturnsMultiUserCredentials() async throws {
        let dir = try makeTempDir()
        let hostsPath = try writeHostsYAML("""
        github.com:
            git_protocol: https
            users:
                alice:
                    oauth_token: gho_alice_token
                bob:
                    oauth_token: gho_bob_token
            user: bob
        """, in: dir)
        let auth = try makeAuth(
            hostsPath: hostsPath,
            keychainRunner: MockProcessRunner(
                tokenByAccount: ["bob": "kc_bob_token"],
                genericToken: "kc_bob_token"
            ),
            loginByToken: ["kc_bob_token": "bob"]
        )

        let batch = try await auth.locateAll()
        let all = batch.credentials
        #expect(all.count == 2)

        let alice = try #require(all.first { $0.login.rawValue == "alice" })
        let bob = try #require(all.first { $0.login.rawValue == "bob" })
        #expect(alice.accessToken == "gho_alice_token")
        #expect(alice.tokenSource == .hostsFile)
        #expect(alice.isActive == false)
        #expect(bob.accessToken == "gho_bob_token")
        #expect(bob.tokenSource == .hostsFile)
        #expect(bob.isActive == true)
    }

    @Test("locateAll() loads per-account keychain token even when unscoped lookup returns another login")
    func locateAllUsesPerAccountKeychainToken() async throws {
        let dir = try makeTempDir()
        let hostsPath = try writeHostsYAML("""
        github.com:
            users:
                LivioGama:
            user: LivioGama
        """, in: dir)
        let auth = try makeAuth(
            hostsPath: hostsPath,
            keychainRunner: MockProcessRunner(
                tokenByAccount: [
                    "LivioGama": "gama_token",
                    "LivioMNC": "liviomnc_token",
                ],
                genericToken: "liviomnc_token"
            ),
            loginByToken: [
                "gama_token": "LivioGama",
                "liviomnc_token": "LivioMNC",
            ]
        )

        let batch = try await auth.locateAll()
        #expect(batch.credentials.count == 2)

        let gama = try #require(batch.credentials.first { $0.login.rawValue == "LivioGama" })
        let mnc = try #require(batch.credentials.first { $0.login.rawValue == "LivioMNC" })
        #expect(gama.accessToken == "gama_token")
        #expect(gama.tokenSource == .keychain)
        #expect(gama.isActive == true)
        #expect(mnc.accessToken == "liviomnc_token")
        #expect(mnc.tokenSource == .keychain)
        #expect(mnc.isActive == false)
    }

    @Test("locateAll() resolves unscoped-only keychain token when per-account entry is absent")
    func locateAllUsesUnscopedKeychainToken() async throws {
        let dir = try makeTempDir()
        let hostsPath = try writeHostsYAML("""
        github.com:
            user: alice
        """, in: dir)
        let auth = try makeAuth(
            hostsPath: hostsPath,
            keychainRunner: MockProcessRunner(genericToken: "legacy_token"),
            loginByToken: ["legacy_token": "alice"]
        )

        let batch = try await auth.locateAll()
        #expect(batch.activeLogin.rawValue == "alice")
        #expect(batch.credentials.count == 1)
        #expect(batch.credentials[0].accessToken == "legacy_token")
        #expect(batch.credentials[0].tokenSource == .keychain)
    }

    @Test("locate() throws when active login has no token but another login does")
    func locateThrowsWhenActiveLoginHasNoToken() async throws {
        let dir = try makeTempDir()
        let hostsPath = try writeHostsYAML("""
        github.com:
            user: eve
        """, in: dir)
        let auth = try makeAuth(
            hostsPath: hostsPath,
            keychainRunner: MockProcessRunner(
                tokenByAccount: ["bob": "bob_token"],
                genericToken: "bob_token"
            ),
            loginByToken: ["bob_token": "bob"]
        )

        do {
            _ = try await auth.locate()
            Issue.record("Expected noTokenAvailable for active login eve")
        } catch let error as CopilotCredentialLocatorError {
            if case .noTokenAvailable(let login) = error {
                #expect(login == "eve")
            } else {
                Issue.record("Expected noTokenAvailable, got \(error)")
            }
        }
    }

    @Test("locateAll() assigns host-level oauth_token only to the active login")
    func locateAllHostLevelTokenActiveOnly() async throws {
        let dir = try makeTempDir()
        let hostsPath = try writeHostsYAML("""
        github.com:
            users:
                alice:
                bob:
            user: bob
            oauth_token: gho_shared_token
        """, in: dir)
        let auth = try makeAuth(
            hostsPath: hostsPath,
            keychainRunner: MockProcessRunner(failureExitCode: 44)
        )

        let batch = try await auth.locateAll()
        #expect(batch.credentials.count == 1)
        #expect(batch.credentials[0].login.rawValue == "bob")
        #expect(batch.credentials[0].accessToken == "gho_shared_token")
    }
}
