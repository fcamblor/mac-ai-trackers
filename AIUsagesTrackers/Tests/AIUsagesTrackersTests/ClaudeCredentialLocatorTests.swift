import Foundation
import Testing
@testable import AIUsagesTrackersLib

@Suite("ClaudeCredentialLocator")
struct ClaudeCredentialLocatorTests {
    private struct MockProcessRunner: ProcessRunning {
        let result: ProcessExecutionResult

        func run(executablePath: String, arguments: [String], timeoutSeconds: Int) async throws -> ProcessExecutionResult {
            result
        }
    }

    private func makeTempLogger() -> FileLogger {
        let dir = NSTemporaryDirectory() + "ai-tracker-claude-locator-\(UUID().uuidString)"
        try! FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        return FileLogger(filePath: "\(dir)/test.log", minLevel: .debug)
    }

    private func keychainResult(json: String) -> ProcessExecutionResult {
        ProcessExecutionResult(stdout: Data(json.utf8), terminationStatus: 0, timedOut: false)
    }

    private static let fixedNow = Date(timeIntervalSince1970: 1_715_000_000)
    private let fixedClock: @Sendable () -> Date = { Self.fixedNow }

    @Test("returns token when expiresAt is in the future")
    func validToken() async throws {
        let futureMillis = Int((Self.fixedNow.timeIntervalSince1970 + 3600) * 1000)
        let locator = ClaudeCredentialLocator(
            processRunner: MockProcessRunner(result: keychainResult(json: #"{"claudeAiOauth":{"accessToken":"tok-abc","expiresAt":\#(futureMillis)}}"#)),
            logger: makeTempLogger(),
            clock: fixedClock
        )

        let creds = try await locator.locate()
        #expect(creds.accessToken == "tok-abc")
    }

    @Test("throws tokenExpired when expiresAt is in the past")
    func expiredToken() async throws {
        let pastMillis = Int((Self.fixedNow.timeIntervalSince1970 - 10) * 1000)
        let locator = ClaudeCredentialLocator(
            processRunner: MockProcessRunner(result: keychainResult(json: #"{"claudeAiOauth":{"accessToken":"tok-abc","expiresAt":\#(pastMillis)}}"#)),
            logger: makeTempLogger(),
            clock: fixedClock
        )

        await #expect(throws: ClaudeAuthError.self) {
            try await locator.locate()
        }
    }

    @Test("throws tokenExpired within the skew window even if absolute expiry is in the near future")
    func expiringSoonTriggersSkew() async throws {
        // 30s in the future — under the 60s skew margin, so should be considered expired.
        let nearFutureMillis = Int((Self.fixedNow.timeIntervalSince1970 + 30) * 1000)
        let locator = ClaudeCredentialLocator(
            processRunner: MockProcessRunner(result: keychainResult(json: #"{"claudeAiOauth":{"accessToken":"tok-abc","expiresAt":\#(nearFutureMillis)}}"#)),
            logger: makeTempLogger(),
            clock: fixedClock
        )

        await #expect(throws: ClaudeAuthError.self) {
            try await locator.locate()
        }
    }

    @Test("missing expiresAt skips local check and returns token")
    func missingExpiresAt() async throws {
        let locator = ClaudeCredentialLocator(
            processRunner: MockProcessRunner(result: keychainResult(json: #"{"claudeAiOauth":{"accessToken":"tok-abc"}}"#)),
            logger: makeTempLogger(),
            clock: fixedClock
        )

        let creds = try await locator.locate()
        #expect(creds.accessToken == "tok-abc")
    }

    @Test("expiresAt as numeric string is accepted")
    func expiresAtAsString() async throws {
        let futureMillis = Int((Self.fixedNow.timeIntervalSince1970 + 3600) * 1000)
        let locator = ClaudeCredentialLocator(
            processRunner: MockProcessRunner(result: keychainResult(json: #"{"claudeAiOauth":{"accessToken":"tok-abc","expiresAt":"\#(futureMillis)"}}"#)),
            logger: makeTempLogger(),
            clock: fixedClock
        )

        let creds = try await locator.locate()
        #expect(creds.accessToken == "tok-abc")
    }

    @Test("expiresAt as malformed value skips local check and returns token")
    func malformedExpiresAt() async throws {
        let locator = ClaudeCredentialLocator(
            processRunner: MockProcessRunner(result: keychainResult(json: #"{"claudeAiOauth":{"accessToken":"tok-abc","expiresAt":"not-a-number"}}"#)),
            logger: makeTempLogger(),
            clock: fixedClock
        )

        let creds = try await locator.locate()
        #expect(creds.accessToken == "tok-abc")
    }

    @Test("non-zero security exit code surfaces keychainAccessDenied")
    func keychainDenied() async throws {
        let locator = ClaudeCredentialLocator(
            processRunner: MockProcessRunner(result: ProcessExecutionResult(stdout: Data(), terminationStatus: 44, timedOut: false)),
            logger: makeTempLogger(),
            clock: fixedClock
        )

        await #expect(throws: ClaudeAuthError.self) {
            try await locator.locate()
        }
    }

    @Test("empty stdout surfaces keychainEmpty")
    func keychainEmpty() async throws {
        let locator = ClaudeCredentialLocator(
            processRunner: MockProcessRunner(result: ProcessExecutionResult(stdout: Data(), terminationStatus: 0, timedOut: false)),
            logger: makeTempLogger(),
            clock: fixedClock
        )

        await #expect(throws: ClaudeAuthError.self) {
            try await locator.locate()
        }
    }

    // MARK: - Account auto-pin / reset

    /// Two-stage runner: an attribute-only call (no `-w`) returns the
    /// `security` CLI's human-formatted dump, the secret-data call (`-w`)
    /// returns the JSON payload. Lets tests assert behaviour around the
    /// no-override → discover acct → pin flow without spinning up a real
    /// Keychain.
    private final class TwoStageRunner: ProcessRunning, @unchecked Sendable {
        // swiftlint:disable:next w4_unchecked_sendable — captured by tests on a single Task; no concurrent mutation.
        let attributeStdout: Data
        let attributeStatus: Int32
        // Keyed by the `-a` argument used at the call site; `nil` covers the
        // unscoped call (no `-a`). Each entry is the `-w` payload + status.
        let passwordResultsByAccount: [String?: ProcessExecutionResult]
        private(set) var capturedArguments: [[String]] = []

        init(
            attributeStdout: Data,
            attributeStatus: Int32 = 0,
            passwordResultsByAccount: [String?: ProcessExecutionResult]
        ) {
            self.attributeStdout = attributeStdout
            self.attributeStatus = attributeStatus
            self.passwordResultsByAccount = passwordResultsByAccount
        }

        func run(executablePath: String, arguments: [String], timeoutSeconds: Int) async throws -> ProcessExecutionResult {
            capturedArguments.append(arguments)
            if arguments.contains("-w") {
                let account: String?
                if let idx = arguments.firstIndex(of: "-a"),
                   arguments.indices.contains(arguments.index(after: idx)) {
                    account = arguments[arguments.index(after: idx)]
                } else {
                    account = nil
                }
                return passwordResultsByAccount[account]
                    ?? ProcessExecutionResult(stdout: Data(), terminationStatus: 44, timedOut: false)
            }
            return ProcessExecutionResult(stdout: attributeStdout, terminationStatus: attributeStatus, timedOut: false)
        }
    }

    private static let attributesDump = """
    keychain: "/Users/foo/Library/Keychains/login.keychain-db"
    class: "genp"
    attributes:
        0x00000007 <blob>="Claude Code-credentials"
        "acct"<blob>="juherr"
        "svce"<blob>="Claude Code-credentials"
    """

    @Test("parses acct attribute out of security CLI dump")
    func parseAcctAttribute() {
        #expect(ClaudeCredentialLocator.parseAccountAttribute(from: Self.attributesDump) == "juherr")
    }

    @Test("auto-pins acct of first read when no override is set")
    func autoPinFirstRead() async throws {
        let futureMillis = Int((Self.fixedNow.timeIntervalSince1970 + 3600) * 1000)
        let runner = TwoStageRunner(
            attributeStdout: Data(Self.attributesDump.utf8),
            passwordResultsByAccount: [
                "juherr": keychainResult(json: #"{"claudeAiOauth":{"accessToken":"tok-abc","expiresAt":\#(futureMillis)}}"#),
            ]
        )
        let pinned = LockBox<String?>(nil)
        let locator = ClaudeCredentialLocator(
            processRunner: runner,
            logger: makeTempLogger(),
            clock: fixedClock,
            accountOverride: { nil },
            accountPersistor: { value in pinned.set(value) }
        )

        let creds = try await locator.locate()
        #expect(creds.accessToken == "tok-abc")
        #expect(pinned.get() == "juherr")
    }

    @Test("auto-pins acct even when token has expired")
    func autoPinOnExpired() async throws {
        let pastMillis = Int((Self.fixedNow.timeIntervalSince1970 - 10) * 1000)
        let runner = TwoStageRunner(
            attributeStdout: Data(Self.attributesDump.utf8),
            passwordResultsByAccount: [
                "juherr": keychainResult(json: #"{"claudeAiOauth":{"accessToken":"tok-abc","expiresAt":\#(pastMillis)}}"#),
            ]
        )
        let pinned = LockBox<String?>(nil)
        let locator = ClaudeCredentialLocator(
            processRunner: runner,
            logger: makeTempLogger(),
            clock: fixedClock,
            accountOverride: { nil },
            accountPersistor: { value in pinned.set(value) }
        )

        await #expect(throws: ClaudeAuthError.self) {
            try await locator.locate()
        }
        // Even though we threw tokenExpired, the acct must be pinned so future
        // refreshes target the same entry once the CLI rotates the token.
        #expect(pinned.get() == "juherr")
    }

    @Test("resets stale pin when override points at non-claudeAiOauth entry")
    func resetStalePin() async throws {
        let futureMillis = Int((Self.fixedNow.timeIntervalSince1970 + 3600) * 1000)
        let runner = TwoStageRunner(
            attributeStdout: Data(Self.attributesDump.utf8),
            passwordResultsByAccount: [
                // Override hit: MCP entry with no claudeAiOauth — triggers reset.
                "unknown": keychainResult(json: #"{"mcpOAuth":{"foo":"bar"}}"#),
                // Post-reset retry: attribute lookup re-discovers acct=juherr,
                // which then reads successfully and is pinned in its place.
                "juherr": keychainResult(json: #"{"claudeAiOauth":{"accessToken":"tok-new","expiresAt":\#(futureMillis)}}"#),
            ]
        )
        let pinned = LockBox<String?>("unknown")
        let locator = ClaudeCredentialLocator(
            processRunner: runner,
            logger: makeTempLogger(),
            // Override starts as the stale pin "unknown", then the persistor
            // resets it to nil so the second pass goes through the attribute
            // discovery path.
            clock: fixedClock,
            accountOverride: { pinned.get() },
            accountPersistor: { value in pinned.set(value) }
        )

        let creds = try await locator.locate()
        #expect(creds.accessToken == "tok-new")
        // After reset + re-discover, the pin should now be "juherr".
        #expect(pinned.get() == "juherr")
    }

    @Test("resets stale pin when selected account is no longer found")
    func resetStalePinWhenSelectedAccountMissing() async throws {
        let futureMillis = Int((Self.fixedNow.timeIntervalSince1970 + 3600) * 1000)
        let runner = TwoStageRunner(
            attributeStdout: Data(Self.attributesDump.utf8),
            passwordResultsByAccount: [
                "unknown": ProcessExecutionResult(stdout: Data(), terminationStatus: 44, timedOut: false),
                "juherr": keychainResult(json: #"{"claudeAiOauth":{"accessToken":"tok-new","expiresAt":\#(futureMillis)}}"#),
            ]
        )
        let pinned = LockBox<String?>("unknown")
        let locator = ClaudeCredentialLocator(
            processRunner: runner,
            logger: makeTempLogger(),
            clock: fixedClock,
            accountOverride: { pinned.get() },
            accountPersistor: { value in pinned.set(value) }
        )

        let creds = try await locator.locate()
        #expect(creds.accessToken == "tok-new")
        #expect(pinned.get() == "juherr")
    }

    @Test("does not reset explicit pin on non-not-found keychain access failure")
    func preservesPinOnAccessDenied() async throws {
        let deniedExitCode: Int32 = 51
        let runner = TwoStageRunner(
            attributeStdout: Data(Self.attributesDump.utf8),
            passwordResultsByAccount: [
                "juherr": ProcessExecutionResult(stdout: Data(), terminationStatus: deniedExitCode, timedOut: false),
            ]
        )
        let pinned = LockBox<String?>("juherr")
        let locator = ClaudeCredentialLocator(
            processRunner: runner,
            logger: makeTempLogger(),
            clock: fixedClock,
            accountOverride: { pinned.get() },
            accountPersistor: { value in pinned.set(value) }
        )

        await #expect(throws: ClaudeAuthError.self) {
            try await locator.locate()
        }
        #expect(pinned.get() == "juherr")
        #expect(runner.capturedArguments.count == 2)
    }

    @Test("missingOAuthBlock surfaces when JSON has no claudeAiOauth and override is unset")
    func missingOAuthBlockWithoutOverride() async throws {
        let runner = TwoStageRunner(
            attributeStdout: Data(),
            attributeStatus: 44,
            passwordResultsByAccount: [
                nil: keychainResult(json: #"{"mcpOAuth":{"foo":"bar"}}"#),
            ]
        )
        let pinned = LockBox<String?>(nil)
        let locator = ClaudeCredentialLocator(
            processRunner: runner,
            logger: makeTempLogger(),
            clock: fixedClock,
            accountOverride: { nil },
            accountPersistor: { value in pinned.set(value) }
        )

        await #expect(throws: ClaudeAuthError.self) {
            try await locator.locate()
        }
        // The persistor must not be invoked when the read fails before the
        // `claudeAiOauth` gate — otherwise a bad entry would silently get
        // pinned and the next poll would loop on the same failure.
        #expect(pinned.get() == nil)
    }

    @Test("parseAccountAttribute decodes hex-encoded acct payloads")
    func parseAcctHexDecoded() {
        let dump = """
        attributes:
            "acct"<blob>=0x6A75686572720A  "juherr"
        """
        #expect(ClaudeCredentialLocator.parseAccountAttribute(from: dump) == "juherr")
    }

    @Test("maskIdentifier preserves first and last chars, masks the middle")
    func maskIdentifierShapes() {
        // Length >= 4: keep first 2 and last 2, mask the middle.
        #expect(ClaudeCredentialLocator.maskIdentifier("juherr") == "ju**rr")
        #expect(ClaudeCredentialLocator.maskIdentifier("frederic.camblor@4sh.fr") == "fr*******************fr")
        #expect(ClaudeCredentialLocator.maskIdentifier("abcd") == "abcd")
        // Length < 4: reduce window to first 1 and last 1 so we don't over-overlap.
        #expect(ClaudeCredentialLocator.maskIdentifier("abc") == "a*c")
        #expect(ClaudeCredentialLocator.maskIdentifier("ab") == "ab")
        #expect(ClaudeCredentialLocator.maskIdentifier("a") == "a")
        #expect(ClaudeCredentialLocator.maskIdentifier("") == "")
    }
}

/// Minimal Sendable mutable cell used by tests that need to observe the
/// `accountPersistor` callback while also feeding the current pin into the
/// `accountOverride` closure. Both closures are `@Sendable` so we can't just
/// share a `var` — wrap it in a lock instead.
private final class LockBox<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value

    init(_ initial: Value) { self.value = initial }

    func get() -> Value {
        lock.lock(); defer { lock.unlock() }
        return value
    }

    func set(_ newValue: Value) {
        lock.lock(); defer { lock.unlock() }
        value = newValue
    }
}
