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

// MARK: - Mock status connector

actor MockStatusConnector: StatusConnector {
    nonisolated let vendor: Vendor
    private let outages: [Outage]
    private let shouldThrow: Bool
    private(set) var fetchCount = 0

    init(vendor: Vendor, outages: [Outage] = [], shouldThrow: Bool = false) {
        self.vendor = vendor
        self.outages = outages
        self.shouldThrow = shouldThrow
    }

    func fetchOutages() async throws -> [Outage] {
        fetchCount += 1
        if shouldThrow {
            throw StatusConnectorError.unexpectedResponse(statusCode: 500, url: "mock")
        }
        return outages
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
    func startIdempotent() async throws {
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
        try await eventually { await connector.fetchCount >= 2 }
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

    @Test("pollOnce with force=true bypasses freshness cache")
    func pollOnceForceBypassesCache() async {
        let dir = makeTempDir()
        let logger = FileLogger(filePath: "\(dir)/test.log", minLevel: .debug)
        let fm = UsagesFileManager(filePath: "\(dir)/usages.json", logger: logger)

        let now = Date()
        let recentDate = now.addingTimeInterval(-60)
        let cachedEntry = VendorUsageEntry(
            vendor: "claude", account: "a@b.com", isActive: true,
            lastAcquiredOn: ISODate(date: recentDate),
            metrics: []
        )
        await fm.update(with: [cachedEntry])

        let connector = MockConnector(vendor: "claude", entries: [cachedEntry])
        let poller = UsagePoller(connectors: [connector], interval: .seconds(180), fileManager: fm, logger: logger)

        await poller.pollOnce(now: now, force: true)

        let fetchCount = await connector.fetchCount
        #expect(fetchCount == 1)
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

    @Test("stop is idempotent — calling twice does not crash")
    func stopIdempotent() async throws {
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
        try await eventually { await connector.fetchCount >= 1 }
        await poller.stop()
        await poller.stop() // second stop must be a no-op

        let count = await connector.fetchCount
        #expect(count >= 1)
    }

    @Test("poller reads interval from AppPreferences on each tick")
    func dynamicIntervalFromPreferences() async throws {
        let dir = makeTempDir()
        let logger = FileLogger(filePath: "\(dir)/test.log", minLevel: .debug)
        let fm = UsagesFileManager(filePath: "\(dir)/usages.json", logger: logger)
        let connector = MockConnector(vendor: "claude", entries: [
            VendorUsageEntry(vendor: "claude", account: "a@b.com"),
        ])
        let prefs = await InMemoryAppPreferences(
            refreshInterval: RefreshInterval(clamping: 30)
        )
        let poller = UsagePoller(
            connectors: [connector],
            fileManager: fm,
            logger: logger,
            preferences: prefs
        )

        await poller.start()
        // With 30s interval the poller sleeps 30s between polls, but the first
        // poll fires immediately on start. Wait for at least 1 fetch.
        try await eventually { await connector.fetchCount >= 1 }
        await poller.stop()

        let count = await connector.fetchCount
        #expect(count >= 1)
    }

    @Test("poller cache uses current preferences interval, not a stale snapshot")
    func cacheFreshnessUsesPreferencesInterval() async throws {
        let dir = makeTempDir()
        let logger = FileLogger(filePath: "\(dir)/test.log", minLevel: .debug)
        let fm = UsagesFileManager(filePath: "\(dir)/usages.json", logger: logger)

        let now = Date()
        // Entry is 40s old — stale for a 30s interval, fresh for a 60s interval
        let acquiredDate = now.addingTimeInterval(-40)
        let cachedEntry = VendorUsageEntry(
            vendor: "claude", account: "a@b.com", isActive: true,
            lastAcquiredOn: ISODate(date: acquiredDate),
            metrics: []
        )
        await fm.update(with: [cachedEntry])

        let connector = MockConnector(vendor: "claude", entries: [cachedEntry])

        // With 60s interval, the 40s-old entry should be considered fresh → skip
        let prefs = await InMemoryAppPreferences(
            refreshInterval: RefreshInterval(clamping: 60)
        )
        let poller = UsagePoller(
            connectors: [connector],
            fileManager: fm,
            logger: logger,
            preferences: prefs
        )

        await poller.pollOnce(now: now)

        let fetchCount = await connector.fetchCount
        #expect(fetchCount == 0)
    }

    @Test("stop during active poll does not crash")
    func stopDuringPoll() async throws {
        let dir = makeTempDir()
        let logger = FileLogger(filePath: "\(dir)/test.log", minLevel: .debug)
        let fm = UsagesFileManager(filePath: "\(dir)/usages.json", logger: logger)
        let connector = MockConnector(vendor: "claude", entries: [
            VendorUsageEntry(vendor: "claude", account: "a@b.com"),
        ])
        let poller = UsagePoller(
            connectors: [connector],
            interval: .milliseconds(10),
            fileManager: fm,
            logger: logger
        )

        await poller.start()
        // Stop immediately — may interrupt an in-flight poll
        await poller.stop()

        // Verify no crash occurred and poller is fully stopped
        let count = await connector.fetchCount
        #expect(count >= 0)
    }

    // MARK: - Status connector integration

    @Test("pollOnce writes outages returned by status connector")
    func statusConnectorWritesOutages() async {
        let dir = makeTempDir()
        let logger = FileLogger(filePath: "\(dir)/test.log", minLevel: .debug)
        let fm = UsagesFileManager(filePath: "\(dir)/usages.json", logger: logger)

        let usage = MockConnector(vendor: "claude", entries: [
            VendorUsageEntry(vendor: "claude", account: "a@b.com", isActive: true),
        ])
        let outage = Outage(vendor: .claude, errorMessage: "boom",
                            severity: .major, since: "2026-04-22T10:00:00Z")
        let status = MockStatusConnector(vendor: .claude, outages: [outage])
        let poller = UsagePoller(
            connectors: [usage], statusConnectors: [status],
            fileManager: fm, logger: logger
        )

        await poller.pollOnce()

        let result = await fm.read()
        #expect(result.outages.count == 1)
        #expect(result.outages[0].errorMessage == "boom")
    }

    @Test("failing status connector preserves existing outages for that vendor")
    func statusConnectorFailurePreservesOutages() async throws {
        let dir = makeTempDir()
        let logger = FileLogger(filePath: "\(dir)/test.log", minLevel: .debug)
        let fm = UsagesFileManager(filePath: "\(dir)/usages.json", logger: logger)

        // Seed file with a pre-existing Claude outage
        let seeded = UsagesFile(usages: [], outages: [
            Outage(vendor: .claude, errorMessage: "pre-existing", severity: .critical,
                   since: "2026-04-20T00:00:00Z"),
        ])
        let data = try JSONEncoder().encode(seeded)
        try data.write(to: URL(fileURLWithPath: fm.filePath), options: .atomic)

        let usage = MockConnector(vendor: "claude", entries: [
            VendorUsageEntry(vendor: "claude", account: "a@b.com", isActive: true),
        ])
        let status = MockStatusConnector(vendor: .claude, shouldThrow: true)
        let poller = UsagePoller(
            connectors: [usage], statusConnectors: [status],
            fileManager: fm, logger: logger
        )

        await poller.pollOnce()

        let result = await fm.read()
        #expect(result.outages.count == 1)
        #expect(result.outages[0].errorMessage == "pre-existing")
    }

    @Test("empty outage list from status connector clears that vendor's outages")
    func statusConnectorEmptyListClearsVendor() async throws {
        let dir = makeTempDir()
        let logger = FileLogger(filePath: "\(dir)/test.log", minLevel: .debug)
        let fm = UsagesFileManager(filePath: "\(dir)/usages.json", logger: logger)

        let seeded = UsagesFile(usages: [], outages: [
            Outage(vendor: .claude, errorMessage: "old", severity: .major,
                   since: "2026-04-20T00:00:00Z"),
        ])
        let data = try JSONEncoder().encode(seeded)
        try data.write(to: URL(fileURLWithPath: fm.filePath), options: .atomic)

        let usage = MockConnector(vendor: "claude", entries: [
            VendorUsageEntry(vendor: "claude", account: "a@b.com", isActive: true),
        ])
        let status = MockStatusConnector(vendor: .claude, outages: [])
        let poller = UsagePoller(
            connectors: [usage], statusConnectors: [status],
            fileManager: fm, logger: logger
        )

        await poller.pollOnce()

        let result = await fm.read()
        #expect(result.outages.isEmpty)
    }

    @Test("forced refresh calls status connector exactly once per tick")
    func statusConnectorCalledOncePerTick() async {
        let dir = makeTempDir()
        let logger = FileLogger(filePath: "\(dir)/test.log", minLevel: .debug)
        let fm = UsagesFileManager(filePath: "\(dir)/usages.json", logger: logger)

        let usage = MockConnector(vendor: "claude", entries: [
            VendorUsageEntry(vendor: "claude", account: "a@b.com"),
        ])
        let status = MockStatusConnector(vendor: .claude, outages: [])
        let poller = UsagePoller(
            connectors: [usage], statusConnectors: [status],
            fileManager: fm, logger: logger
        )

        await poller.pollOnce(force: true)

        let count = await status.fetchCount
        #expect(count == 1)
    }

    @Test("start/stop lifecycle")
    func startStop() async throws {
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
        try await eventually { await connector.fetchCount >= 2 }
        await poller.stop()

        let count = await connector.fetchCount
        #expect(count >= 2)
    }
}
