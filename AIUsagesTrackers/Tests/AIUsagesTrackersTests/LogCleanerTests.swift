import Foundation
import Testing
@testable import AIUsagesTrackersLib

// Guarded by NSLock — all access goes through lock/unlock // justification: test-only counter
private final class AtomicCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var _value = 0

    var value: Int {
        lock.lock()
        defer { lock.unlock() }
        return _value
    }

    func increment() {
        lock.lock()
        _value += 1
        lock.unlock()
    }
}

@Suite("LogCleaner")
struct LogCleanerTests {
    private func makeTempLogger() -> FileLogger {
        let path = NSTemporaryDirectory() + "ai-tracker-log-\(UUID().uuidString)/test.log"
        return FileLogger(filePath: path, minLevel: .debug)
    }

    private func writeLines(_ lines: String, to logger: FileLogger) throws {
        try lines.data(using: .utf8)!.write(to: URL(fileURLWithPath: logger.filePath), options: .atomic)
    }

    @Test("cleanOnce purges old lines from all managed loggers")
    func cleanOncePurgesAll() async throws {
        let logger1 = makeTempLogger()
        let logger2 = makeTempLogger()
        let fmt = ISO8601DateFormatter()
        let fixedNow = Date()
        let eightDaysAgo = fixedNow.addingTimeInterval(-8 * 24 * 60 * 60)
        let sixDaysAgo = fixedNow.addingTimeInterval(-6 * 24 * 60 * 60)

        let old = fmt.string(from: eightDaysAgo)
        let recent = fmt.string(from: sixDaysAgo)

        try writeLines("[\(old)] [INFO] old\n[\(recent)] [INFO] recent\n", to: logger1)
        try writeLines("[\(old)] [INFO] old\n", to: logger2)

        let cleaner = LogCleaner(
            loggers: [logger1, logger2],
            now: { fixedNow },
            logger: logger1
        )
        await cleaner.cleanOnce()

        let content1 = try String(contentsOfFile: logger1.filePath, encoding: .utf8)
        #expect(content1 == "[\(recent)] [INFO] recent\n")

        let content2 = try String(contentsOfFile: logger2.filePath, encoding: .utf8)
        #expect(content2 == "")
    }

    @Test("start is idempotent — second call does not spawn a second task")
    func startIdempotent() async throws {
        let logger = makeTempLogger()
        let counter = AtomicCounter()

        let cleaner = LogCleaner(
            loggers: [logger],
            tickInterval: .milliseconds(10),
            now: { Date() },
            sleep: { duration in
                counter.increment()
                try await Task.sleep(for: duration)
            },
            logger: logger
        )

        await cleaner.start()
        await cleaner.start() // second call — should be no-op

        try await Task.sleep(for: .milliseconds(100))

        let count = counter.value
        // If two tasks were spawned, count would roughly double.
        #expect(count < 20, "Too many sleep calls (\(count)), likely two tasks running")

        await cleaner.stop()
    }

    @Test("stop cancels the task and start can resume")
    func stopThenRestart() async throws {
        let logger = makeTempLogger()
        let counter = AtomicCounter()

        let cleaner = LogCleaner(
            loggers: [logger],
            tickInterval: .milliseconds(10),
            now: { Date() },
            sleep: { duration in
                counter.increment()
                try await Task.sleep(for: duration)
            },
            logger: logger
        )

        await cleaner.start()
        try await Task.sleep(for: .milliseconds(50))
        await cleaner.stop()

        let countAfterStop = counter.value

        try await Task.sleep(for: .milliseconds(50))
        let countLater = counter.value
        #expect(countLater == countAfterStop, "Ticks continued after stop")

        // Restart should work
        await cleaner.start()
        try await Task.sleep(for: .milliseconds(50))
        await cleaner.stop()

        let countAfterRestart = counter.value
        #expect(countAfterRestart > countAfterStop, "No ticks after restart")
    }

    @Test("cleanOnce handles missing files without crash")
    func cleanOnceMissingFile() async {
        let logger = makeTempLogger()
        let cleaner = LogCleaner(
            loggers: [logger],
            now: { Date() },
            logger: logger
        )
        await cleaner.cleanOnce()
    }

    @Test("clock injection drives the cutoff correctly")
    func clockInjection() async throws {
        let logger = makeTempLogger()
        let fmt = ISO8601DateFormatter()
        let fixedNow = Date()
        let almostSevenDays = fixedNow.addingTimeInterval(-6 * 24 * 60 * 60 - 23 * 60 * 60)
        let justOverSevenDays = fixedNow.addingTimeInterval(-7 * 24 * 60 * 60 - 60 * 60)

        let kept = fmt.string(from: almostSevenDays)
        let dropped = fmt.string(from: justOverSevenDays)

        try writeLines("[\(dropped)] [INFO] dropped\n[\(kept)] [INFO] kept\n", to: logger)

        let cleaner = LogCleaner(
            loggers: [logger],
            now: { fixedNow },
            logger: logger
        )
        await cleaner.cleanOnce()

        let content = try String(contentsOfFile: logger.filePath, encoding: .utf8)
        #expect(content == "[\(kept)] [INFO] kept\n")
    }
}
