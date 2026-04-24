import Foundation
import Testing
@testable import AIUsagesTrackersLib

@Suite("CodexAuth")
struct CodexAuthTests {
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

    private func makeTempDir() throws -> String {
        let dir = NSTemporaryDirectory() + "ai-tracker-codex-auth-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        return dir
    }

    private func writeAuthJSON(_ json: String, in dir: String, filename: String = "auth.json") throws -> String {
        let path = "\(dir)/\(filename)"
        try json.write(toFile: path, atomically: true, encoding: .utf8)
        return path
    }

    private func makeAuth(codexHomePath: String) throws -> CodexAuth {
        let dir = NSTemporaryDirectory() + "ai-tracker-codex-auth-log-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let logger = FileLogger(filePath: "\(dir)/test.log", minLevel: .debug)
        return CodexAuth(codexHomePath: codexHomePath, logger: logger)
    }

    private func makeKeychainAuth(result: ProcessExecutionResult) throws -> CodexAuth {
        let dir = try makeTempDir()
        let logger = FileLogger(filePath: "\(dir)/test.log", minLevel: .debug)
        return CodexAuth(
            codexHomePath: nil,
            fileManager: EmptyFileManager(home: URL(fileURLWithPath: dir)),
            logger: logger,
            processRunner: MockProcessRunner(result: result)
        )
    }

    // MARK: - File parsing

    @Test("loads credentials from CODEX_HOME/auth.json")
    func loadsFromCodexHome() async throws {
        let dir = try makeTempDir()
        _ = try writeAuthJSON(
            #"{"tokens":{"access_token":"tok-abc","account_id":"acct-001"},"last_refresh":"2026-04-20T10:00:00.000Z"}"#,
            in: dir
        )
        let auth = try makeAuth(codexHomePath: dir)
        let credentials = try await auth.load()

        #expect(credentials.accessToken == "tok-abc")
        #expect(credentials.accountId == "acct-001")
        #expect(credentials.lastRefreshedAt != nil)
    }

    @Test("parses last_refresh ISO8601 date with fractional seconds")
    func parsesLastRefresh() async throws {
        let dir = try makeTempDir()
        _ = try writeAuthJSON(
            #"{"tokens":{"access_token":"tok","account_id":"acct-001"},"last_refresh":"2026-04-15T08:30:00.123Z"}"#,
            in: dir
        )
        let auth = try makeAuth(codexHomePath: dir)
        let credentials = try await auth.load()

        #expect(credentials.lastRefreshedAt != nil)
        // Verify the date is roughly April 15, 2026
        let calendar = Calendar(identifier: .gregorian)
        let components = calendar.dateComponents([.year, .month, .day], from: credentials.lastRefreshedAt!)
        #expect(components.year == 2026)
        #expect(components.month == 4)
        #expect(components.day == 15)
    }

    @Test("lastRefreshedAt is nil when last_refresh field is absent")
    func lastRefreshAbsent() async throws {
        let dir = try makeTempDir()
        _ = try writeAuthJSON(
            #"{"tokens":{"access_token":"tok","account_id":"acct-001"}}"#,
            in: dir
        )
        let auth = try makeAuth(codexHomePath: dir)
        let credentials = try await auth.load()

        #expect(credentials.lastRefreshedAt == nil)
    }

    @Test("throws parseFailed when JSON is malformed")
    func throwsParseFailedOnMalformedJSON() async throws {
        let dir = try makeTempDir()
        _ = try writeAuthJSON("not valid json {{{", in: dir)
        let auth = try makeAuth(codexHomePath: dir)

        await #expect(throws: CodexAuthError.self) {
            try await auth.load()
        }
    }

    @Test("throws missingAccountId when tokens.account_id is absent")
    func throwsMissingAccountId() async throws {
        let dir = try makeTempDir()
        _ = try writeAuthJSON(
            #"{"tokens":{"access_token":"tok"}}"#,
            in: dir
        )
        let auth = try makeAuth(codexHomePath: dir)

        do {
            _ = try await auth.load()
            Issue.record("Expected missingAccountId error, but load succeeded")
        } catch let error as CodexAuthError {
            if case .missingAccountId = error {
                // expected
            } else {
                Issue.record("Expected missingAccountId, got \(error)")
            }
        } catch {
            Issue.record("Expected CodexAuthError, got \(error)")
        }
    }

    @Test("throws parseFailed when access_token is empty")
    func throwsParseFailedOnEmptyAccessToken() async throws {
        let dir = try makeTempDir()
        _ = try writeAuthJSON(
            #"{"tokens":{"access_token":"","account_id":"acct-001"}}"#,
            in: dir
        )
        let auth = try makeAuth(codexHomePath: dir)

        await #expect(throws: CodexAuthError.self) {
            try await auth.load()
        }
    }

    @Test("reads valid credentials when auth.json has extra unknown keys")
    func toleratesUnknownTopLevelKeys() async throws {
        let dir = try makeTempDir()
        _ = try writeAuthJSON(
            #"{"tokens":{"access_token":"tok","account_id":"acct-001"},"unknown_field":"ignored","version":2}"#,
            in: dir
        )
        let auth = try makeAuth(codexHomePath: dir)
        let credentials = try await auth.load()

        #expect(credentials.accessToken == "tok")
        #expect(credentials.accountId == "acct-001")
    }

    @Test("loads credentials from keychain JSON fallback")
    func loadsFromKeychainJSON() async throws {
        let stdout = #"{"tokens":{"access_token":"tok-keychain","account_id":"acct-keychain"}}"#.data(using: .utf8)!
        let auth = try makeKeychainAuth(result: ProcessExecutionResult(stdout: stdout, terminationStatus: 0, timedOut: false))

        let credentials = try await auth.load()

        #expect(credentials.accessToken == "tok-keychain")
        #expect(credentials.accountId == "acct-keychain")
    }

    @Test("loads credentials from hex-encoded keychain JSON fallback")
    func loadsFromHexKeychainJSON() async throws {
        let raw = #"{"tokens":{"access_token":"tok-hex","account_id":"acct-hex"}}"#
        let hex = "0x" + raw.utf8.map { String(format: "%02x", $0) }.joined()
        let auth = try makeKeychainAuth(result: ProcessExecutionResult(
            stdout: Data(hex.utf8),
            terminationStatus: 0,
            timedOut: false
        ))

        let credentials = try await auth.load()

        #expect(credentials.accessToken == "tok-hex")
        #expect(credentials.accountId == "acct-hex")
    }

    @Test("throws keychainTimeout when process runner times out")
    func throwsKeychainTimeout() async throws {
        let auth = try makeKeychainAuth(result: ProcessExecutionResult(stdout: Data(), terminationStatus: 15, timedOut: true))

        await #expect(throws: CodexAuthError.self) {
            try await auth.load()
        }
    }
}
