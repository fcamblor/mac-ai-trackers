import Foundation
import Testing
@testable import AIUsagesTrackersLib

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

    private func makeMonitor(dir: String, configPath: String) -> (ClaudeActiveAccountMonitor, UsagesFileManager) {
        let logger = FileLogger(filePath: "\(dir)/test.log", minLevel: .debug)
        let fileManager = UsagesFileManager(filePath: "\(dir)/usages.json", logger: logger)
        let monitor = ClaudeActiveAccountMonitor(
            claudeConfigPath: configPath,
            fileManager: fileManager,
            logger: logger,
            interval: .seconds(3600)
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

    @Test("checkOnce deactivates all accounts when config has no oauthAccount")
    func checkOnceDeactivatesWhenNoOauth() async {
        let dir = makeTempDir()
        let configPath = writeConfig("{}", to: dir)
        let (monitor, fileManager) = makeMonitor(dir: dir, configPath: configPath)
        await fileManager.update(with: [
            VendorUsageEntry(vendor: "claude", account: "user@example.com", isActive: true),
        ])

        await monitor.checkOnce()

        let result = await fileManager.read()
        #expect(result.usages[0].isActive == false)
    }

    @Test("checkOnce deactivates all accounts when config file is missing")
    func checkOnceDeactivatesWhenFileMissing() async {
        let dir = makeTempDir()
        let (monitor, fileManager) = makeMonitor(dir: dir, configPath: "\(dir)/missing.json")
        await fileManager.update(with: [
            VendorUsageEntry(vendor: "claude", account: "user@example.com", isActive: true),
        ])

        await monitor.checkOnce()

        let result = await fileManager.read()
        #expect(result.usages[0].isActive == false)
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
