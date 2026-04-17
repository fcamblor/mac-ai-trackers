import Foundation
import Testing
@testable import AIUsagesTrackersLib

// MARK: - Mock connector

actor MockConnector: UsageConnector {
    nonisolated let vendor: String
    private let entries: [VendorUsageEntry]
    private let shouldThrow: Bool
    private(set) var fetchCount = 0

    init(vendor: String, entries: [VendorUsageEntry], shouldThrow: Bool = false) {
        self.vendor = vendor
        self.entries = entries
        self.shouldThrow = shouldThrow
    }

    nonisolated func resolveActiveAccount() -> String? {
        entries.first?.account
    }

    func fetchUsages() async throws -> [VendorUsageEntry] {
        fetchCount += 1
        if shouldThrow { throw ConnectorError.unexpectedAPIFormat }
        return entries
    }
}

// MARK: - Tests

@Suite("UsagePoller")
struct UsagePollerTests {
    private func makeTempDir() -> String {
        let dir = NSTemporaryDirectory() + "ai-tracker-poller-\(UUID().uuidString)"
        try! FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        return dir
    }

    @Test("pollOnce writes entries to file")
    func pollOnceWrites() async {
        let dir = makeTempDir()
        let logger = FileLogger(filePath: "\(dir)/test.log", minLevel: .debug)
        let fm = UsagesFileManager(filePath: "\(dir)/usages.json", logger: logger)
        let entry = VendorUsageEntry(vendor: "claude", account: "a@b.com", isActive: true, metrics: [
            .timeWindow(name: "session", resetAt: "2026-04-17T15:00:00+00:00",
                        windowDurationMinutes: 300, usagePercent: 42),
        ])
        let connector = MockConnector(vendor: "claude", entries: [entry])
        let poller = UsagePoller(connectors: [connector], fileManager: fm, logger: logger)

        await poller.pollOnce()

        let result = await fm.read()
        #expect(result.usages.count == 1)
        #expect(result.usages[0].account == "a@b.com")
    }

    @Test("pollOnce with throwing connector still writes other connectors' results")
    func pollOncePartialFailure() async {
        let dir = makeTempDir()
        let logger = FileLogger(filePath: "\(dir)/test.log", minLevel: .debug)
        let fm = UsagesFileManager(filePath: "\(dir)/usages.json", logger: logger)

        let good = MockConnector(vendor: "claude", entries: [
            VendorUsageEntry(vendor: "claude", account: "a@b.com", isActive: true),
        ])
        let bad = MockConnector(vendor: "codex", entries: [], shouldThrow: true)
        let poller = UsagePoller(connectors: [good, bad], fileManager: fm, logger: logger)

        await poller.pollOnce()

        let result = await fm.read()
        #expect(result.usages.count == 1)
        #expect(result.usages[0].vendor == "claude")
    }

    @Test("pollOnce with all connectors failing writes nothing")
    func pollOnceAllFail() async {
        let dir = makeTempDir()
        let logger = FileLogger(filePath: "\(dir)/test.log", minLevel: .debug)
        let fm = UsagesFileManager(filePath: "\(dir)/usages.json", logger: logger)

        let bad = MockConnector(vendor: "claude", entries: [], shouldThrow: true)
        let poller = UsagePoller(connectors: [bad], fileManager: fm, logger: logger)

        await poller.pollOnce()

        let result = await fm.read()
        #expect(result.usages.isEmpty)
    }

    @Test("pollOnce aggregates multiple connectors")
    func pollOnceMultipleConnectors() async {
        let dir = makeTempDir()
        let logger = FileLogger(filePath: "\(dir)/test.log", minLevel: .debug)
        let fm = UsagesFileManager(filePath: "\(dir)/usages.json", logger: logger)

        let c1 = MockConnector(vendor: "claude", entries: [
            VendorUsageEntry(vendor: "claude", account: "a@b.com", isActive: true),
        ])
        let c2 = MockConnector(vendor: "codex", entries: [
            VendorUsageEntry(vendor: "codex", account: "c@d.com", isActive: true),
        ])
        let poller = UsagePoller(connectors: [c1, c2], fileManager: fm, logger: logger)

        await poller.pollOnce()

        let result = await fm.read()
        #expect(result.usages.count == 2)
    }

    @Test("start is idempotent — calling twice does not double-poll")
    func startIdempotent() async {
        let dir = makeTempDir()
        let logger = FileLogger(filePath: "\(dir)/test.log", minLevel: .debug)
        let fm = UsagesFileManager(filePath: "\(dir)/usages.json", logger: logger)
        let connector = MockConnector(vendor: "claude", entries: [
            VendorUsageEntry(vendor: "claude", account: "a@b.com"),
        ])
        let poller = UsagePoller(
            connectors: [connector],
            interval: .milliseconds(50),
            fileManager: fm,
            logger: logger
        )

        await poller.start()
        await poller.start() // second call should be no-op
        try? await Task.sleep(for: .milliseconds(200))
        await poller.stop()

        // If start were not idempotent, fetchCount would roughly double
        let count = await connector.fetchCount
        #expect(count >= 2 && count <= 6)
    }

    @Test("start/stop lifecycle")
    func startStop() async {
        let dir = makeTempDir()
        let logger = FileLogger(filePath: "\(dir)/test.log", minLevel: .debug)
        let fm = UsagesFileManager(filePath: "\(dir)/usages.json", logger: logger)
        let connector = MockConnector(vendor: "claude", entries: [
            VendorUsageEntry(vendor: "claude", account: "a@b.com"),
        ])
        let poller = UsagePoller(
            connectors: [connector],
            interval: .milliseconds(50),
            fileManager: fm,
            logger: logger
        )

        await poller.start()
        try? await Task.sleep(for: .milliseconds(200))
        await poller.stop()

        let count = await connector.fetchCount
        #expect(count >= 2)
    }
}
