import Foundation
import Testing
@testable import AIUsagesTrackersLib

private actor AccountChangeRecorder {
    private(set) var accounts: [AccountEmail] = []
    func record(_ account: AccountEmail) { accounts.append(account) }
}

@Suite("ClaudeActiveAccountMonitor")
struct ClaudeActiveAccountMonitorTests {
    private func makeTempDir() -> String {
        let dir = NSTemporaryDirectory() + "ai-tracker-monitor-\(UUID().uuidString)"
        try! FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        return dir
    }

    private func writeConfig(_ json: String, to dir: String) -> String {
        let path = "\(dir)/claude.json"
        try! json.write(toFile: path, atomically: true, encoding: .utf8)
        return path
    }

    private func makeMonitor(
        dir: String,
        configPath: String,
        onActiveAccountChanged: (@Sendable (AccountEmail) async -> Void)? = nil
    ) -> (ClaudeActiveAccountMonitor, UsagesFileManager) {
        let logger = FileLogger(filePath: "\(dir)/test.log", minLevel: .debug)
        let fileManager = UsagesFileManager(filePath: "\(dir)/usages.json", logger: logger)
        let monitor = ClaudeActiveAccountMonitor(
            claudeConfigPath: configPath,
            fileManager: fileManager,
            logger: logger,
            interval: .seconds(3600),
            onActiveAccountChanged: onActiveAccountChanged
        )
        return (monitor, fileManager)
    }

    @Test("checkOnce marks the active account when a valid config exists")
    func checkOnceActivatesMatchingAccount() async {
        let dir = makeTempDir()
        let configPath = writeConfig(
            #"{"oauthAccount":{"emailAddress":"user@example.com"}}"#,
            to: dir
        )
        let (monitor, fileManager) = makeMonitor(dir: dir, configPath: configPath)
        await fileManager.update(with: [
            VendorUsageEntry(vendor: "claude", account: "user@example.com", isActive: false),
            VendorUsageEntry(vendor: "claude", account: "other@example.com", isActive: true),
        ])

        await monitor.checkOnce()

        let result = await fileManager.read()
        let byAccount = Dictionary(uniqueKeysWithValues: result.usages.map { ($0.account, $0.isActive) })
        #expect(byAccount["user@example.com"] == true)
        #expect(byAccount["other@example.com"] == false)
    }

    @Test("checkOnce preserves isActive when config has no oauthAccount (transient /login state)")
    func checkOncePreservesWhenNoOauth() async {
        let dir = makeTempDir()
        let configPath = writeConfig("{}", to: dir)
        let (monitor, fileManager) = makeMonitor(dir: dir, configPath: configPath)
        await fileManager.update(with: [
            VendorUsageEntry(vendor: "claude", account: "user@example.com", isActive: true),
        ])

        await monitor.checkOnce()

        let result = await fileManager.read()
        #expect(result.usages[0].isActive == true)
    }

    @Test("checkOnce preserves isActive when config file is missing")
    func checkOncePreservesWhenFileMissing() async {
        let dir = makeTempDir()
        let (monitor, fileManager) = makeMonitor(dir: dir, configPath: "\(dir)/missing.json")
        await fileManager.update(with: [
            VendorUsageEntry(vendor: "claude", account: "user@example.com", isActive: true),
        ])

        await monitor.checkOnce()

        let result = await fileManager.read()
        #expect(result.usages[0].isActive == true)
    }

    @Test("onActiveAccountChanged fires when switching between two accounts")
    func callbackFiresOnAccountSwitch() async {
        let dir = makeTempDir()
        let configPath = writeConfig(
            #"{"oauthAccount":{"emailAddress":"first@example.com"}}"#,
            to: dir
        )
        let recorder = AccountChangeRecorder()
        let (monitor, _) = makeMonitor(
            dir: dir,
            configPath: configPath,
            onActiveAccountChanged: { account in await recorder.record(account) }
        )

        // First tick sets the baseline — no callback expected.
        await monitor.checkOnce()
        #expect(await recorder.accounts.isEmpty)

        // Simulate a /login switch by rewriting the config.
        _ = writeConfig(
            #"{"oauthAccount":{"emailAddress":"second@example.com"}}"#,
            to: dir
        )
        await monitor.checkOnce()

        #expect(await recorder.accounts == ["second@example.com"])
    }

    @Test("onActiveAccountChanged does not fire on idempotent tick")
    func callbackSilentWhenAccountUnchanged() async {
        let dir = makeTempDir()
        let configPath = writeConfig(
            #"{"oauthAccount":{"emailAddress":"user@example.com"}}"#,
            to: dir
        )
        let recorder = AccountChangeRecorder()
        let (monitor, _) = makeMonitor(
            dir: dir,
            configPath: configPath,
            onActiveAccountChanged: { account in await recorder.record(account) }
        )

        await monitor.checkOnce()
        await monitor.checkOnce()
        await monitor.checkOnce()

        #expect(await recorder.accounts.isEmpty)
    }

    @Test("start/stop idempotence — double start does not crash")
    func startIdempotent() async {
        let dir = makeTempDir()
        let configPath = writeConfig(
            #"{"oauthAccount":{"emailAddress":"user@example.com"}}"#,
            to: dir
        )
        let (monitor, _) = makeMonitor(dir: dir, configPath: configPath)
        await monitor.start()
        await monitor.start()
        await monitor.stop()
    }

    @Test("stop on non-started monitor does not crash")
    func stopBeforeStart() async {
        let dir = makeTempDir()
        let configPath = writeConfig("{}", to: dir)
        let (monitor, _) = makeMonitor(dir: dir, configPath: configPath)
        await monitor.stop()
    }
}
