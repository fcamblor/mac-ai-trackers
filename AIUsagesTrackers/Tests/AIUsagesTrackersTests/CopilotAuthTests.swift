import Foundation
import Testing
@testable import AIUsagesTrackersLib

@Suite("CopilotAuth")
struct CopilotAuthTests {
    private struct MockProcessRunner: ProcessRunning {
        let result: ProcessExecutionResult

        func run(executablePath: String, arguments: [String], timeoutSeconds: Int) async throws -> ProcessExecutionResult {
            result
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

    private func makeAuth(
        hostsPath: String? = nil,
        environment: [String: String] = [:],
        keychainResult: ProcessExecutionResult? = nil
    ) throws -> CopilotCredentialLocator {
        let dir = try makeTempDir()
        let logger = FileLogger(filePath: "\(dir)/test.log", minLevel: .debug)
        let runner = MockProcessRunner(result: keychainResult ?? ProcessExecutionResult(
            stdout: Data(), terminationStatus: 44, timedOut: false
        ))
        // FileManager.default lets the auth read the override path written by tests;
        // we don't risk hitting the real ~/.config/gh/hosts.yml because the override
        // short-circuits the candidate-path cascade.
        return CopilotCredentialLocator(
            environment: environment,
            hostsFilePathOverride: hostsPath,
            fileManager: .default,
            logger: logger,
            processRunner: runner
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
            environment: ["GITHUB_TOKEN": "env_token"],
            keychainResult: ProcessExecutionResult(stdout: Data("kc_token".utf8), terminationStatus: 0, timedOut: false)
        )

        let credentials = try await auth.locate()
        #expect(credentials.accessToken == "env_token")
        #expect(credentials.tokenSource == .envVar)
        #expect(credentials.activeLogin.rawValue == "alice")
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
            keychainResult: ProcessExecutionResult(stdout: Data("kc_token\n".utf8), terminationStatus: 0, timedOut: false)
        )

        let credentials = try await auth.locate()
        #expect(credentials.accessToken == "kc_token")
        #expect(credentials.tokenSource == .keychain)
        #expect(credentials.activeLogin.rawValue == "bob")
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
            keychainResult: ProcessExecutionResult(stdout: Data(encoded.utf8), terminationStatus: 0, timedOut: false)
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
            keychainResult: ProcessExecutionResult(stdout: Data(), terminationStatus: 44, timedOut: false)
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
            keychainResult: ProcessExecutionResult(stdout: Data(), terminationStatus: 44, timedOut: false)
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
            keychainResult: ProcessExecutionResult(stdout: Data(), terminationStatus: 15, timedOut: true)
        )

        await #expect(throws: CopilotCredentialLocatorError.self) {
            try await auth.locate()
        }
    }
}
