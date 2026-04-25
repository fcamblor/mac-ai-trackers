import Foundation
import Testing
@testable import AIUsagesTrackersLib

// Mock recorder that records calls and can simulate a transient failure.
actor MockSnapshotRecorder: SnapshotRecording {
    private(set) var calls: [(file: UsagesFile, now: Date)] = []
    private var failOnCallIndices: Set<Int> = []

    func failOn(callIndex: Int) {
        failOnCallIndices.insert(callIndex)
    }

    func callCount() -> Int { calls.count }

    func recordSnapshot(from file: UsagesFile, now: Date) async {
        // "Failure" is modelled as a no-op on disk; the scheduler doesn't inspect
        // the return value, so we simply record the call. This mirrors the real
        // recorder's swallow-and-log policy for I/O errors.
        let shouldFail = failOnCallIndices.contains(calls.count)
        calls.append((file, now))
        if shouldFail { return }
    }
}

@Suite("SnapshotScheduler")
struct SnapshotSchedulerTests {
    private static func makeTempDir() -> String {
        let dir = NSTemporaryDirectory() + "ai-tracker-scheduler-\(UUID().uuidString)"
        try! FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        return dir
    }

    @Test("tickOnce reads the file manager and forwards to recorder")
    func tickReadsAndForwards() async {
        let dir = Self.makeTempDir()
        let logger = FileLogger(filePath: "\(dir)/test.log", minLevel: .debug)
        let fm = UsagesFileManager(filePath: "\(dir)/usages.json", logger: logger)
        let seed = VendorUsageEntry(vendor: "claude", account: "a@b.com", metrics: [
            .timeWindow(name: "session", resetAt: nil, windowDuration: 300, usagePercent: 42),
        ])
        await fm.update(with: [seed])

        let recorder = MockSnapshotRecorder()
        let clock = FixedClock(Date(timeIntervalSince1970: 1_000_000))
        let scheduler = SnapshotScheduler(
            fileManager: fm,
            recorder: recorder,
            clock: clock,
            interval: .seconds(60),
            logger: logger
        )

        await scheduler.tickOnce()

        let calls = await recorder.calls
        #expect(calls.count == 1)
        #expect(calls[0].file.usages.count == 1)
        #expect(calls[0].now == clock.now())
    }

    @Test("start is idempotent")
    func startIdempotent() async {
        let dir = Self.makeTempDir()
        let logger = FileLogger(filePath: "\(dir)/test.log", minLevel: .debug)
        let fm = UsagesFileManager(filePath: "\(dir)/usages.json", logger: logger)
        let recorder = MockSnapshotRecorder()
        let scheduler = SnapshotScheduler(
            fileManager: fm,
            recorder: recorder,
            interval: .seconds(3600),
            logger: logger
        )

        await scheduler.start()
        await scheduler.start()
        await scheduler.stop()
    }

    @Test("stop is idempotent")
    func stopIdempotent() async {
        let dir = Self.makeTempDir()
        let logger = FileLogger(filePath: "\(dir)/test.log", minLevel: .debug)
        let fm = UsagesFileManager(filePath: "\(dir)/usages.json", logger: logger)
        let recorder = MockSnapshotRecorder()
        let scheduler = SnapshotScheduler(
            fileManager: fm,
            recorder: recorder,
            interval: .seconds(3600),
            logger: logger
        )

        await scheduler.stop()
        await scheduler.stop()
        await scheduler.start()
        await scheduler.stop()
        await scheduler.stop()
    }

    @Test("a recorder failure does not interrupt subsequent ticks")
    func recoversFromRecorderFailure() async {
        let dir = Self.makeTempDir()
        let logger = FileLogger(filePath: "\(dir)/test.log", minLevel: .debug)
        let fm = UsagesFileManager(filePath: "\(dir)/usages.json", logger: logger)
        let seed = VendorUsageEntry(vendor: "claude", account: "a@b.com", metrics: [
            .timeWindow(name: "session", resetAt: nil, windowDuration: 300, usagePercent: 42),
        ])
        await fm.update(with: [seed])

        let recorder = MockSnapshotRecorder()
        await recorder.failOn(callIndex: 0)
        let scheduler = SnapshotScheduler(
            fileManager: fm,
            recorder: recorder,
            interval: .seconds(3600),
            logger: logger
        )

        await scheduler.tickOnce()
        await scheduler.tickOnce()

        let count = await recorder.callCount()
        #expect(count == 2)
    }
}
