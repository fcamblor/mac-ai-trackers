import Foundation
import Testing
@testable import AIUsagesTrackersLib

@Suite("SnapshotRecorder")
struct SnapshotRecorderTests {
    // Fixed-timezone calendar so path partitioning is deterministic across CI runners.
    private static func utcCalendar() -> Calendar {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        return cal
    }

    private static func makeTempRoot() -> String {
        let dir = NSTemporaryDirectory() + "ai-tracker-snapshot-\(UUID().uuidString)"
        try! FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        return dir
    }

    private static func makeLogger(in dir: String) -> FileLogger {
        FileLogger(filePath: "\(dir)/test.log", minLevel: .debug)
    }

    private static func isoDate(_ rawValue: String) -> Date {
        ISO8601DateFormatter().date(from: rawValue)!
    }

    private static func expectedPath(root: String, year: String, month: String, day: String) -> String {
        "\(root)/\(year)/\(month)/\(year)-\(month)-\(day).jsonl"
    }

    private static func readLines(_ path: String) -> [String] {
        guard let data = try? String(contentsOfFile: path, encoding: .utf8) else { return [] }
        return data.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
    }

    private static func decode(_ line: String) -> TickSnapshot? {
        try? JSONDecoder().decode(TickSnapshot.self, from: Data(line.utf8))
    }

    // MARK: - Shape

    @Test("default recorder partitions files by UTC date, not local time")
    func defaultCalendarIsUTC() async {
        let root = Self.makeTempRoot()
        let recorder = SnapshotRecorder(
            rootPath: root,
            logger: Self.makeLogger(in: root)
            // no calendar arg — uses the production default
        )
        let file = UsagesFile(usages: [
            VendorUsageEntry(vendor: "claude", account: "a@b.com", metrics: [
                .timeWindow(name: "session", resetAt: nil, windowDuration: 300, usagePercent: 42),
            ]),
        ])

        // A UTC midnight — e.g. 2026-04-25T00:30:00Z is still "2026-04-25" in UTC
        // but could be "2026-04-24" in a timezone west of UTC (e.g. UTC-1 or later).
        let utcMidnight = Self.isoDate("2026-04-25T00:30:00Z")
        await recorder.recordSnapshot(from: file, now: utcMidnight)

        let expectedPath = Self.expectedPath(root: root, year: "2026", month: "04", day: "25")
        #expect(FileManager.default.fileExists(atPath: expectedPath))
    }

    @Test("writes a single line per tick containing every vendor/account/metric")
    func writesOneLinePerTick() async {
        let root = Self.makeTempRoot()
        let recorder = SnapshotRecorder(
            rootPath: root,
            logger: Self.makeLogger(in: root),
            calendar: Self.utcCalendar()
        )
        let file = UsagesFile(usages: [
            VendorUsageEntry(vendor: "claude", account: "a@b.com", metrics: [
                .timeWindow(name: "session", resetAt: nil, windowDuration: 300, usagePercent: 42),
                .timeWindow(name: "weekly", resetAt: nil, windowDuration: 10_080, usagePercent: 17),
            ]),
            VendorUsageEntry(vendor: "codex", account: "c@d.com", metrics: [
                .payAsYouGo(name: "spend", currentAmount: 12.34, currency: "USD"),
            ]),
        ])

        await recorder.recordSnapshot(from: file, now: Self.isoDate("2026-04-19T12:00:00Z"))

        let path = Self.expectedPath(root: root, year: "2026", month: "04", day: "19")
        let lines = Self.readLines(path)
        #expect(lines.count == 1)

        let tick = Self.decode(lines[0])
        #expect(tick != nil)
        #expect(tick?.timestamp.rawValue == "2026-04-19T12:00:00Z")
        #expect(tick?.accounts.count == 2)
        #expect(tick?.accounts.first(where: { $0.vendor == "claude" })?.metrics.count == 2)
        #expect(tick?.accounts.first(where: { $0.vendor == "codex" })?.metrics.first?.currentAmount == 12.34)
    }

    @Test("serialized line starts with the timestamp field for readability")
    func timestampIsFirstField() async {
        let root = Self.makeTempRoot()
        let recorder = SnapshotRecorder(
            rootPath: root,
            logger: Self.makeLogger(in: root),
            calendar: Self.utcCalendar()
        )
        let file = UsagesFile(usages: [
            VendorUsageEntry(vendor: "claude", account: "a@b.com", metrics: [
                .timeWindow(name: "session", resetAt: nil, windowDuration: 300, usagePercent: 42),
            ]),
        ])

        await recorder.recordSnapshot(from: file, now: Self.isoDate("2026-04-19T12:00:00Z"))

        let path = Self.expectedPath(root: root, year: "2026", month: "04", day: "19")
        let lines = Self.readLines(path)
        #expect(lines.count == 1)
        // The JSON object must open with `"timestamp"` — readers scanning the
        // file by eye (or by prefix) rely on that field being the first key.
        #expect(lines[0].hasPrefix("{\"timestamp\":"))
    }

    // MARK: - Skip behaviour

    @Test("skips ticks with no metrics")
    func skipsEmptyTick() async {
        let root = Self.makeTempRoot()
        let recorder = SnapshotRecorder(
            rootPath: root,
            logger: Self.makeLogger(in: root),
            calendar: Self.utcCalendar()
        )

        await recorder.recordSnapshot(from: UsagesFile(), now: Self.isoDate("2026-04-19T12:00:00Z"))

        let path = Self.expectedPath(root: root, year: "2026", month: "04", day: "19")
        #expect(!FileManager.default.fileExists(atPath: path))
    }

    @Test("skips a tick whose payload hash matches the previous write")
    func skipsUnchangedTick() async {
        let root = Self.makeTempRoot()
        let recorder = SnapshotRecorder(
            rootPath: root,
            logger: Self.makeLogger(in: root),
            calendar: Self.utcCalendar()
        )
        let file = UsagesFile(usages: [
            VendorUsageEntry(vendor: "claude", account: "a@b.com", metrics: [
                .timeWindow(name: "session", resetAt: nil, windowDuration: 300, usagePercent: 10),
            ]),
        ])

        await recorder.recordSnapshot(from: file, now: Self.isoDate("2026-04-19T12:00:00Z"))
        await recorder.recordSnapshot(from: file, now: Self.isoDate("2026-04-19T12:01:00Z"))

        let path = Self.expectedPath(root: root, year: "2026", month: "04", day: "19")
        let lines = Self.readLines(path)
        #expect(lines.count == 1)
    }

    @Test("writes again when any metric value changes")
    func writesAfterChange() async {
        let root = Self.makeTempRoot()
        let recorder = SnapshotRecorder(
            rootPath: root,
            logger: Self.makeLogger(in: root),
            calendar: Self.utcCalendar()
        )
        let file1 = UsagesFile(usages: [
            VendorUsageEntry(vendor: "claude", account: "a@b.com", metrics: [
                .timeWindow(name: "session", resetAt: nil, windowDuration: 300, usagePercent: 10),
            ]),
        ])
        let file2 = UsagesFile(usages: [
            VendorUsageEntry(vendor: "claude", account: "a@b.com", metrics: [
                .timeWindow(name: "session", resetAt: nil, windowDuration: 300, usagePercent: 11),
            ]),
        ])

        await recorder.recordSnapshot(from: file1, now: Self.isoDate("2026-04-19T12:00:00Z"))
        await recorder.recordSnapshot(from: file2, now: Self.isoDate("2026-04-19T12:01:00Z"))

        let path = Self.expectedPath(root: root, year: "2026", month: "04", day: "19")
        let lines = Self.readLines(path)
        #expect(lines.count == 2)
    }

    @Test("writes again when an account appears or disappears")
    func writesWhenAccountSetChanges() async {
        let root = Self.makeTempRoot()
        let recorder = SnapshotRecorder(
            rootPath: root,
            logger: Self.makeLogger(in: root),
            calendar: Self.utcCalendar()
        )
        let single = UsagesFile(usages: [
            VendorUsageEntry(vendor: "claude", account: "a@b.com", metrics: [
                .timeWindow(name: "session", resetAt: nil, windowDuration: 300, usagePercent: 10),
            ]),
        ])
        let pair = UsagesFile(usages: [
            VendorUsageEntry(vendor: "claude", account: "a@b.com", metrics: [
                .timeWindow(name: "session", resetAt: nil, windowDuration: 300, usagePercent: 10),
            ]),
            VendorUsageEntry(vendor: "codex", account: "c@d.com", metrics: [
                .payAsYouGo(name: "spend", currentAmount: 5.0, currency: "USD"),
            ]),
        ])

        await recorder.recordSnapshot(from: single, now: Self.isoDate("2026-04-19T12:00:00Z"))
        await recorder.recordSnapshot(from: pair, now: Self.isoDate("2026-04-19T12:01:00Z"))

        let path = Self.expectedPath(root: root, year: "2026", month: "04", day: "19")
        let lines = Self.readLines(path)
        #expect(lines.count == 2)
        #expect(Self.decode(lines[0])?.accounts.count == 1)
        #expect(Self.decode(lines[1])?.accounts.count == 2)
    }

    @Test("hash ignores the timestamp so dedup only compares payloads")
    func hashIsTimestampIndependent() throws {
        let accounts = [
            AccountSnapshot(vendor: "claude", account: "a@b.com", metrics: [
                MetricSnapshot(name: "session", kind: .timeWindow, usagePercent: 42),
            ]),
        ]
        let h1 = try SnapshotRecorder.hash(of: accounts)
        let h2 = try SnapshotRecorder.hash(of: accounts)
        #expect(h1 == h2)
        #expect(!h1.isEmpty)

        let other = [
            AccountSnapshot(vendor: "claude", account: "a@b.com", metrics: [
                MetricSnapshot(name: "session", kind: .timeWindow, usagePercent: 43),
            ]),
        ]
        let h3 = try SnapshotRecorder.hash(of: other)
        #expect(h1 != h3)
    }

    // MARK: - Files & rollover

    @Test("creates the file on the first tick")
    func createsFileOnFirstTick() async {
        let root = Self.makeTempRoot()
        let recorder = SnapshotRecorder(
            rootPath: root,
            logger: Self.makeLogger(in: root),
            calendar: Self.utcCalendar()
        )
        let file = UsagesFile(usages: [
            VendorUsageEntry(vendor: "claude", account: "a@b.com", metrics: [
                .timeWindow(name: "session", resetAt: nil, windowDuration: 300, usagePercent: 10),
            ]),
        ])

        let path = Self.expectedPath(root: root, year: "2026", month: "04", day: "19")
        #expect(!FileManager.default.fileExists(atPath: path))

        await recorder.recordSnapshot(from: file, now: Self.isoDate("2026-04-19T12:00:00Z"))

        #expect(FileManager.default.fileExists(atPath: path))
    }

    @Test("dedup persists across recorder restarts when payload is identical")
    func dedupPersistsAcrossRestart() async {
        let root = Self.makeTempRoot()
        let calendar = Self.utcCalendar()
        let logger = Self.makeLogger(in: root)
        let file = UsagesFile(usages: [
            VendorUsageEntry(vendor: "claude", account: "a@b.com", metrics: [
                .timeWindow(name: "session", resetAt: nil, windowDuration: 300, usagePercent: 10),
            ]),
            VendorUsageEntry(vendor: "codex", account: "c@d.com", metrics: [
                .payAsYouGo(name: "spend", currentAmount: 5.0, currency: "USD"),
            ]),
        ])

        let first = SnapshotRecorder(rootPath: root, logger: logger, calendar: calendar)
        await first.recordSnapshot(from: file, now: Self.isoDate("2026-04-19T12:00:00Z"))

        // Simulate process restart: a fresh recorder instance must seed its
        // dedup hash from the last line on disk, not append a duplicate line.
        let second = SnapshotRecorder(rootPath: root, logger: logger, calendar: calendar)
        await second.recordSnapshot(from: file, now: Self.isoDate("2026-04-19T12:01:00Z"))
        await second.recordSnapshot(from: file, now: Self.isoDate("2026-04-19T12:02:00Z"))

        let path = Self.expectedPath(root: root, year: "2026", month: "04", day: "19")
        let lines = Self.readLines(path)
        #expect(lines.count == 1)
    }

    @Test("a restart on a brand-new day starts the new file with a single line")
    func restartOnNewDayWritesFirstLine() async {
        let root = Self.makeTempRoot()
        let calendar = Self.utcCalendar()
        let logger = Self.makeLogger(in: root)
        let file = UsagesFile(usages: [
            VendorUsageEntry(vendor: "claude", account: "a@b.com", metrics: [
                .timeWindow(name: "session", resetAt: nil, windowDuration: 300, usagePercent: 10),
            ]),
        ])

        let first = SnapshotRecorder(rootPath: root, logger: logger, calendar: calendar)
        await first.recordSnapshot(from: file, now: Self.isoDate("2026-04-19T23:59:00Z"))

        // New day after restart: yesterday's file must NOT seed dedup, and the
        // new daily file must receive its first line — even with identical data.
        let second = SnapshotRecorder(rootPath: root, logger: logger, calendar: calendar)
        await second.recordSnapshot(from: file, now: Self.isoDate("2026-04-20T00:01:00Z"))

        let day2 = Self.expectedPath(root: root, year: "2026", month: "04", day: "20")
        let day2Lines = Self.readLines(day2)
        #expect(day2Lines.count == 1)
    }

    @Test("appends without overwriting across recorder instances")
    func appendsAcrossRestart() async {
        let root = Self.makeTempRoot()
        let calendar = Self.utcCalendar()
        let logger = Self.makeLogger(in: root)
        let file1 = UsagesFile(usages: [
            VendorUsageEntry(vendor: "claude", account: "a@b.com", metrics: [
                .timeWindow(name: "session", resetAt: nil, windowDuration: 300, usagePercent: 10),
            ]),
        ])
        let file2 = UsagesFile(usages: [
            VendorUsageEntry(vendor: "claude", account: "a@b.com", metrics: [
                .timeWindow(name: "session", resetAt: nil, windowDuration: 300, usagePercent: 55),
            ]),
        ])

        let first = SnapshotRecorder(rootPath: root, logger: logger, calendar: calendar)
        await first.recordSnapshot(from: file1, now: Self.isoDate("2026-04-19T12:00:00Z"))

        let second = SnapshotRecorder(rootPath: root, logger: logger, calendar: calendar)
        await second.recordSnapshot(from: file2, now: Self.isoDate("2026-04-19T12:01:00Z"))

        let path = Self.expectedPath(root: root, year: "2026", month: "04", day: "19")
        let lines = Self.readLines(path)
        #expect(lines.count == 2)
    }

    @Test("day rollover splits into two files")
    func dayRollover() async {
        let root = Self.makeTempRoot()
        let recorder = SnapshotRecorder(
            rootPath: root,
            logger: Self.makeLogger(in: root),
            calendar: Self.utcCalendar()
        )
        let file1 = UsagesFile(usages: [
            VendorUsageEntry(vendor: "claude", account: "a@b.com", metrics: [
                .timeWindow(name: "session", resetAt: nil, windowDuration: 300, usagePercent: 10),
            ]),
        ])
        let file2 = UsagesFile(usages: [
            VendorUsageEntry(vendor: "claude", account: "a@b.com", metrics: [
                .timeWindow(name: "session", resetAt: nil, windowDuration: 300, usagePercent: 11),
            ]),
        ])

        await recorder.recordSnapshot(from: file1, now: Self.isoDate("2026-04-19T23:59:00Z"))
        await recorder.recordSnapshot(from: file2, now: Self.isoDate("2026-04-20T00:01:00Z"))

        let day1 = Self.expectedPath(root: root, year: "2026", month: "04", day: "19")
        let day2 = Self.expectedPath(root: root, year: "2026", month: "04", day: "20")
        let day1Lines = Self.readLines(day1)
        let day2Lines = Self.readLines(day2)

        #expect(day1Lines.count == 1)
        #expect(day2Lines.count == 1)
        #expect(Self.decode(day1Lines[0])?.accounts.first?.metrics.first?.usagePercent == UsagePercent(rawValue: 10))
        #expect(Self.decode(day2Lines[0])?.accounts.first?.metrics.first?.usagePercent == UsagePercent(rawValue: 11))
    }

    // MARK: - Content validity

    @Test("every line decodes back to a TickSnapshot")
    func linesAreValidJson() async {
        let root = Self.makeTempRoot()
        let recorder = SnapshotRecorder(
            rootPath: root,
            logger: Self.makeLogger(in: root),
            calendar: Self.utcCalendar()
        )
        let file = UsagesFile(usages: [
            VendorUsageEntry(vendor: "claude", account: "a@b.com", metrics: [
                .timeWindow(name: "session", resetAt: nil, windowDuration: 300, usagePercent: 42),
                .payAsYouGo(name: "spend", currentAmount: 1.5, currency: "USD"),
            ]),
        ])

        await recorder.recordSnapshot(from: file, now: Self.isoDate("2026-04-19T12:00:00Z"))

        let path = Self.expectedPath(root: root, year: "2026", month: "04", day: "19")
        let lines = Self.readLines(path)
        for line in lines {
            #expect(Self.decode(line) != nil)
        }
    }

    @Test("ignores unknown metrics and accounts with only unknown metrics")
    func ignoresUnknownMetrics() async {
        let root = Self.makeTempRoot()
        let recorder = SnapshotRecorder(
            rootPath: root,
            logger: Self.makeLogger(in: root),
            calendar: Self.utcCalendar()
        )
        let file = UsagesFile(usages: [
            VendorUsageEntry(vendor: "claude", account: "a@b.com", metrics: [
                .timeWindow(name: "session", resetAt: nil, windowDuration: 300, usagePercent: 42),
                .unknown("future-kind"),
            ]),
            VendorUsageEntry(vendor: "codex", account: "c@d.com", metrics: [
                .unknown("future-kind"),
            ]),
        ])

        await recorder.recordSnapshot(from: file, now: Self.isoDate("2026-04-19T12:00:00Z"))

        let path = Self.expectedPath(root: root, year: "2026", month: "04", day: "19")
        let lines = Self.readLines(path)
        #expect(lines.count == 1)
        let tick = Self.decode(lines[0])
        #expect(tick?.accounts.count == 1)
        #expect(tick?.accounts.first?.vendor == "claude")
        #expect(tick?.accounts.first?.metrics.count == 1)
        #expect(tick?.accounts.first?.metrics.first?.name == "session")
    }
}
