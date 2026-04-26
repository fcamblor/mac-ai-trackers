import Foundation
import Testing
@testable import AIUsagesTrackersLib

@Suite("UsageHistoryReader")
struct UsageHistoryReaderTests {
    private static func makeTempRoot() -> String {
        let dir = NSTemporaryDirectory() + "ai-tracker-history-\(UUID().uuidString)"
        try! FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        return dir
    }

    private static func makeLogger(in dir: String) -> FileLogger {
        FileLogger(filePath: "\(dir)/test.log", minLevel: .debug)
    }

    private static func date(_ rawValue: String) -> Date {
        ISO8601DateFormatter().date(from: rawValue)!
    }

    private static func tick(
        timestamp: String,
        account: AccountEmail = "a@b.com",
        metrics: [MetricSnapshot]
    ) throws -> String {
        let snapshot = TickSnapshot(
            timestamp: ISODate(rawValue: timestamp),
            accounts: [AccountSnapshot(vendor: "claude", account: account, metrics: metrics)]
        )
        let data = try SnapshotRecorder.encode(snapshot)
        return String(decoding: data, as: UTF8.self)
    }

    private static func writeLines(_ lines: [String], to path: String) throws {
        let url = URL(fileURLWithPath: path)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try lines.joined(separator: "\n").appending("\n").write(to: url, atomically: true, encoding: .utf8)
    }

    @Test("loads JSONL snapshots recursively and flattens metric values")
    func loadsSnapshotsRecursively() async throws {
        let root = Self.makeTempRoot()
        try Self.writeLines([
            try Self.tick(timestamp: "2026-04-20T09:00:00Z", metrics: [
                MetricSnapshot(name: "session", kind: .timeWindow, usagePercent: 40),
                MetricSnapshot(name: "spend", kind: .payAsYouGo, currentAmount: 1.25, currency: "USD"),
            ]),
        ], to: "\(root)/2026/04/2026-04-20.jsonl")

        let reader = UsageHistoryReader(rootPath: root, logger: Self.makeLogger(in: root))
        let snapshot = await reader.load(window: .twentyFourHours, now: Self.date("2026-04-20T12:00:00Z"))

        #expect(snapshot.points.count == 2)
        #expect(snapshot.points.contains { $0.metricName == "session" && $0.value == 40 && $0.unit == "%" })
        #expect(snapshot.points.contains { $0.metricName == "spend" && $0.value == 1.25 && $0.unit == "USD" })
        #expect(snapshot.skippedLineCount == 0)
    }

    @Test("reloads cached JSONL files when they change")
    func reloadsCachedFileWhenChanged() async throws {
        let root = Self.makeTempRoot()
        let path = "\(root)/2026/04/2026-04-20.jsonl"
        try Self.writeLines([
            try Self.tick(timestamp: "2026-04-20T09:00:00Z", metrics: [
                MetricSnapshot(name: "session", kind: .timeWindow, usagePercent: 40),
            ]),
        ], to: path)

        let reader = UsageHistoryReader(rootPath: root, logger: Self.makeLogger(in: root))
        let first = await reader.load(window: .twentyFourHours, now: Self.date("2026-04-20T12:00:00Z"))

        try Self.writeLines([
            try Self.tick(timestamp: "2026-04-20T09:00:00Z", metrics: [
                MetricSnapshot(name: "session", kind: .timeWindow, usagePercent: 40),
            ]),
            try Self.tick(timestamp: "2026-04-20T10:00:00Z", metrics: [
                MetricSnapshot(name: "session", kind: .timeWindow, usagePercent: 55),
            ]),
        ], to: path)
        let second = await reader.load(window: .twentyFourHours, now: Self.date("2026-04-20T12:00:00Z"))

        #expect(first.points.map(\.value) == [40.0])
        #expect(second.points.map(\.value) == [40.0, 55.0])
    }

    @Test("filters points outside the selected time window")
    func filtersBySelectedWindow() async throws {
        let root = Self.makeTempRoot()
        try Self.writeLines([
            try Self.tick(timestamp: "2026-04-19T05:00:00Z", metrics: [
                MetricSnapshot(name: "session", kind: .timeWindow, usagePercent: 10),
            ]),
            try Self.tick(timestamp: "2026-04-20T09:00:00Z", metrics: [
                MetricSnapshot(name: "session", kind: .timeWindow, usagePercent: 55),
            ]),
        ], to: "\(root)/2026/04/2026-04-20.jsonl")

        let reader = UsageHistoryReader(rootPath: root, logger: Self.makeLogger(in: root))
        let snapshot = await reader.load(window: .twentyFourHours, now: Self.date("2026-04-20T12:00:00Z"))

        #expect(snapshot.points.map(\.value) == [55.0])
    }

    @Test("reports whether data exists before and after the selected window")
    func reportsDataOutsideSelectedWindow() async throws {
        let root = Self.makeTempRoot()
        try Self.writeLines([
            try Self.tick(timestamp: "2026-04-19T05:00:00Z", metrics: [
                MetricSnapshot(name: "session", kind: .timeWindow, usagePercent: 10),
            ]),
            try Self.tick(timestamp: "2026-04-20T09:00:00Z", metrics: [
                MetricSnapshot(name: "session", kind: .timeWindow, usagePercent: 55),
            ]),
            try Self.tick(timestamp: "2026-04-21T09:00:00Z", metrics: [
                MetricSnapshot(name: "session", kind: .timeWindow, usagePercent: 70),
            ]),
        ], to: "\(root)/2026/04/2026-04-20.jsonl")

        let reader = UsageHistoryReader(rootPath: root, logger: Self.makeLogger(in: root))
        let snapshot = await reader.load(window: .twentyFourHours, now: Self.date("2026-04-20T12:00:00Z"))

        #expect(snapshot.points.map(\.value) == [55.0])
        #expect(snapshot.hasDataBeforeWindow)
        #expect(snapshot.hasDataAfterWindow)
    }

    @Test("all time disables outside-window navigation flags")
    func allTimeDisablesNavigationFlags() async throws {
        let root = Self.makeTempRoot()
        try Self.writeLines([
            try Self.tick(timestamp: "2026-03-01T05:00:00Z", metrics: [
                MetricSnapshot(name: "session", kind: .timeWindow, usagePercent: 10),
            ]),
            try Self.tick(timestamp: "2026-04-20T09:00:00Z", metrics: [
                MetricSnapshot(name: "session", kind: .timeWindow, usagePercent: 55),
            ]),
        ], to: "\(root)/2026/04/2026-04-20.jsonl")

        let reader = UsageHistoryReader(rootPath: root, logger: Self.makeLogger(in: root))
        let snapshot = await reader.load(window: .all, now: Self.date("2026-04-20T12:00:00Z"))

        #expect(!snapshot.hasDataBeforeWindow)
        #expect(!snapshot.hasDataAfterWindow)
    }

    @Test("all time includes older points")
    func allTimeIncludesOlderPoints() async throws {
        let root = Self.makeTempRoot()
        try Self.writeLines([
            try Self.tick(timestamp: "2026-03-01T05:00:00Z", metrics: [
                MetricSnapshot(name: "session", kind: .timeWindow, usagePercent: 10),
            ]),
            try Self.tick(timestamp: "2026-04-20T09:00:00Z", metrics: [
                MetricSnapshot(name: "session", kind: .timeWindow, usagePercent: 55),
            ]),
        ], to: "\(root)/2026/04/2026-04-20.jsonl")

        let reader = UsageHistoryReader(rootPath: root, logger: Self.makeLogger(in: root))
        let snapshot = await reader.load(window: .all, now: Self.date("2026-04-20T12:00:00Z"))

        #expect(snapshot.points.map(\.value) == [10.0, 55.0])
    }

    @Test("skips malformed JSONL lines without failing the whole load")
    func skipsMalformedLines() async throws {
        let root = Self.makeTempRoot()
        try Self.writeLines([
            "{not-json",
            try Self.tick(timestamp: "2026-04-20T09:00:00Z", metrics: [
                MetricSnapshot(name: "session", kind: .timeWindow, usagePercent: 55),
            ]),
        ], to: "\(root)/2026/04/2026-04-20.jsonl")

        let reader = UsageHistoryReader(rootPath: root, logger: Self.makeLogger(in: root))
        let snapshot = await reader.load(window: .twentyFourHours, now: Self.date("2026-04-20T12:00:00Z"))

        #expect(snapshot.points.count == 1)
        #expect(snapshot.skippedLineCount == 1)
    }

    @Test("keeps null metric values so charts can break the line")
    func keepsNullMetricValues() async throws {
        let root = Self.makeTempRoot()
        try Self.writeLines([
            try Self.tick(timestamp: "2026-04-20T09:00:00Z", metrics: [
                MetricSnapshot(name: "session", kind: .timeWindow, usagePercent: 40),
            ]),
            try Self.tick(timestamp: "2026-04-20T10:00:00Z", metrics: [
                MetricSnapshot(name: "session", kind: .timeWindow, usagePercent: nil),
            ]),
            try Self.tick(timestamp: "2026-04-20T11:00:00Z", metrics: [
                MetricSnapshot(name: "session", kind: .timeWindow, usagePercent: 55),
            ]),
        ], to: "\(root)/2026/04/2026-04-20.jsonl")

        let reader = UsageHistoryReader(rootPath: root, logger: Self.makeLogger(in: root))
        let snapshot = await reader.load(window: .twentyFourHours, now: Self.date("2026-04-20T12:00:00Z"))

        #expect(snapshot.points.map(\.value) == [40.0, nil, 55.0])
        #expect(snapshot.seriesSummaries.first?.latestValue == 55)
        #expect(snapshot.seriesSummaries.first?.pointCount == 2)
    }
}
