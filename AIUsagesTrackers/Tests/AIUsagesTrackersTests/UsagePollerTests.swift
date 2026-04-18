import Foundation
import Testing
@testable import AIUsagesTrackersLib

// MARK: - Mock connector

actor MockConnector: UsageConnector {
    nonisolated let vendor: Vendor
    private let entries: [VendorUsageEntry]
    private let shouldThrow: Bool
    private(set) var fetchCount = 0

    init(vendor: Vendor, entries: [VendorUsageEntry], shouldThrow: Bool = false) {
        self.vendor = vendor
        self.entries = entries
        self.shouldThrow = shouldThrow
    }

    nonisolated func resolveActiveAccount() -> AccountEmail? {
        entries.first?.account
    }

    func fetchUsages() async throws -> [VendorUsageEntry] {
        fetchCount += 1
        if shouldThrow { throw ConnectorError.unexpectedAPIFormat(receivedKeys: []) }
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
                        windowDuration: 300, usagePercent: 42),
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

    @Test("pollOnce with no connectors skips file write")
    func pollOnceZeroConnectors() async {
        let dir = makeTempDir()
        let logger = FileLogger(filePath: "\(dir)/test.log", minLevel: .debug)
        let fm = UsagesFileManager(filePath: "\(dir)/usages.json", logger: logger)
        let poller = UsagePoller(connectors: [], fileManager: fm, logger: logger)

        await poller.pollOnce()

        let result = await fm.read()
        #expect(result.usages.isEmpty)
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

    @Test("pollOnce skips fetch when cached data is within interval")
    func pollOnceFreshSkipped() async {
        let dir = makeTempDir()
        let logger = FileLogger(filePath: "\(dir)/test.log", minLevel: .debug)
        let fm = UsagesFileManager(filePath: "\(dir)/usages.json", logger: logger)

        let now = Date()
        let recentDate = now.addingTimeInterval(-60) // 60s ago, well within 180s interval
        let cachedEntry = VendorUsageEntry(
            vendor: "claude", account: "a@b.com", isActive: true,
            lastAcquiredOn: ISODate(date: recentDate),
            metrics: []
        )
        await fm.update(with: [cachedEntry])

        let connector = MockConnector(vendor: "claude", entries: [cachedEntry])
        let poller = UsagePoller(connectors: [connector], interval: .seconds(180), fileManager: fm, logger: logger)

        await poller.pollOnce(now: now)

        let fetchCount = await connector.fetchCount
        #expect(fetchCount == 0)
    }

    @Test("pollOnce fetches when cached data exceeds interval")
    func pollOnceStaleDataFetched() async {
        let dir = makeTempDir()
        let logger = FileLogger(filePath: "\(dir)/test.log", minLevel: .debug)
        let fm = UsagesFileManager(filePath: "\(dir)/usages.json", logger: logger)

        let now = Date()
        let staleDate = now.addingTimeInterval(-200) // 200s ago, past 180s interval
        let staleEntry = VendorUsageEntry(
            vendor: "claude", account: "a@b.com", isActive: true,
            lastAcquiredOn: ISODate(date: staleDate),
            metrics: []
        )
        await fm.update(with: [staleEntry])

        let freshEntry = VendorUsageEntry(
            vendor: "claude", account: "a@b.com", isActive: true,
            lastAcquiredOn: ISODate(date: now),
            metrics: []
        )
        let connector = MockConnector(vendor: "claude", entries: [freshEntry])
        let poller = UsagePoller(connectors: [connector], interval: .seconds(180), fileManager: fm, logger: logger)

        await poller.pollOnce(now: now)

        let fetchCount = await connector.fetchCount
        #expect(fetchCount == 1)
    }

    @Test("pollOnce fetches when no prior entry exists (lastAcquiredOn nil)")
    func pollOnceNoPriorEntry() async {
        let dir = makeTempDir()
        let logger = FileLogger(filePath: "\(dir)/test.log", minLevel: .debug)
        let fm = UsagesFileManager(filePath: "\(dir)/usages.json", logger: logger)

        let entry = VendorUsageEntry(vendor: "claude", account: "a@b.com", isActive: true)
        let connector = MockConnector(vendor: "claude", entries: [entry])
        let poller = UsagePoller(connectors: [connector], interval: .seconds(180), fileManager: fm, logger: logger)

        await poller.pollOnce(now: Date())

        let fetchCount = await connector.fetchCount
        #expect(fetchCount == 1)
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
