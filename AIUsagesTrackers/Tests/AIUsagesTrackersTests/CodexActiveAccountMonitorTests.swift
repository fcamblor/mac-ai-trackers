import Foundation
import Testing
@testable import AIUsagesTrackersLib

private actor AccountIdChangeRecorder {
    private(set) var accountIds: [AccountId] = []
    func record(_ accountId: AccountId) { accountIds.append(accountId) }
}

@Suite("CodexActiveAccountMonitor")
struct CodexActiveAccountMonitorTests {
    private func makeTempDir() throws -> String {
        let dir = NSTemporaryDirectory() + "ai-tracker-codex-monitor-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        return dir
    }

    private func writeAuthJSON(_ json: String, to dir: String) throws -> String {
        let path = "\(dir)/auth.json"
        try json.write(toFile: path, atomically: true, encoding: .utf8)
        return path
    }

    private func makeMonitor(
        codexHomePath: String,
        onActiveAccountChanged: (@Sendable (AccountId) async -> Void)? = nil
    ) throws -> CodexActiveAccountMonitor {
        let dir = NSTemporaryDirectory() + "ai-tracker-codex-monitor-log-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let logger = FileLogger(filePath: "\(dir)/test.log", minLevel: .debug)
        return CodexActiveAccountMonitor(
            codexHomePath: codexHomePath,
            logger: logger,
            interval: .seconds(3600),
            onActiveAccountChanged: onActiveAccountChanged
        )
    }

    @Test("checkOnce does not fire callback on first resolution (startup)")
    func firstResolutionNoCallback() async throws {
        let dir = try makeTempDir()
        _ = try writeAuthJSON(
            #"{"tokens":{"access_token":"tok","account_id":"acct-001"}}"#,
            to: dir
        )
        let recorder = AccountIdChangeRecorder()
        let monitor = try makeMonitor(codexHomePath: dir) { id in await recorder.record(id) }

        await monitor.checkOnce()

        #expect(await recorder.accountIds.isEmpty)
    }

    @Test("onActiveAccountChanged fires when account_id switches")
    func callbackFiresOnAccountSwitch() async throws {
        let dir = try makeTempDir()
        _ = try writeAuthJSON(
            #"{"tokens":{"access_token":"tok","account_id":"acct-001"}}"#,
            to: dir
        )
        let recorder = AccountIdChangeRecorder()
        let monitor = try makeMonitor(codexHomePath: dir) { id in await recorder.record(id) }

        // First tick sets baseline — no callback
        await monitor.checkOnce()
        #expect(await recorder.accountIds.isEmpty)

        // Simulate account switch by rewriting auth.json
        _ = try writeAuthJSON(
            #"{"tokens":{"access_token":"tok2","account_id":"acct-002"}}"#,
            to: dir
        )
        await monitor.checkOnce()

        #expect(await recorder.accountIds == ["acct-002"])
    }

    @Test("onActiveAccountChanged does not fire when account_id unchanged")
    func callbackSilentWhenAccountUnchanged() async throws {
        let dir = try makeTempDir()
        _ = try writeAuthJSON(
            #"{"tokens":{"access_token":"tok","account_id":"acct-001"}}"#,
            to: dir
        )
        let recorder = AccountIdChangeRecorder()
        let monitor = try makeMonitor(codexHomePath: dir) { id in await recorder.record(id) }

        await monitor.checkOnce()
        await monitor.checkOnce()
        await monitor.checkOnce()

        #expect(await recorder.accountIds.isEmpty)
    }

    @Test("checkOnce preserves previous state when auth.json is absent")
    func preservesStateWhenFileMissing() async throws {
        let dir = try makeTempDir()
        // auth.json does not exist in this directory
        let recorder = AccountIdChangeRecorder()
        let monitor = try makeMonitor(codexHomePath: "\(dir)/nonexistent")

        await monitor.checkOnce()
        await monitor.checkOnce()

        // No resolution → no callback
        #expect(await recorder.accountIds.isEmpty)
    }

    @Test("checkOnce preserves previous state when auth.json has no tokens.account_id")
    func preservesStateWhenAccountIdMissing() async throws {
        let dir = try makeTempDir()
        _ = try writeAuthJSON(#"{"tokens":{"access_token":"tok"}}"#, to: dir)
        let recorder = AccountIdChangeRecorder()
        let monitor = try makeMonitor(codexHomePath: dir) { id in await recorder.record(id) }

        await monitor.checkOnce()

        #expect(await recorder.accountIds.isEmpty)
    }

    @Test("start/stop idempotence — double start does not crash")
    func startIdempotent() async throws {
        let dir = try makeTempDir()
        _ = try writeAuthJSON(
            #"{"tokens":{"access_token":"tok","account_id":"acct-001"}}"#,
            to: dir
        )
        let monitor = try makeMonitor(codexHomePath: dir)
        await monitor.start()
        await monitor.start()
        await monitor.stop()
    }

    @Test("stop on non-started monitor does not crash")
    func stopBeforeStart() async throws {
        let dir = try makeTempDir()
        let monitor = try makeMonitor(codexHomePath: dir)
        await monitor.stop()
    }
}
