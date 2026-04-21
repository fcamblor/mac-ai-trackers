import Foundation
import Testing
@testable import AIUsagesTrackersLib

/// Thread-safe mutable LogLevel for testing dynamic level resolution.
private final class MutableLogLevel: @unchecked Sendable { // @unchecked Sendable justified: NSLock guards _value; only this test file mutates it
    private let lock = NSLock()
    private var _value: LogLevel
    init(_ value: LogLevel) { _value = value }
    var value: LogLevel {
        get { lock.withLock { _value } }
        set { lock.withLock { _value = newValue } }
    }
}

@Suite("FileLogger")
struct FileLoggerTests {
    private func makeTempPath() -> String {
        NSTemporaryDirectory() + "ai-tracker-log-\(UUID().uuidString)/test.log"
    }

    @Test("creates directory and log file on first write")
    func createsFile() {
        let path = makeTempPath()
        let logger = FileLogger(filePath: path, minLevel: .debug)
        logger.log(.info, "hello")
        logger.waitForPendingWrites()
        #expect(FileManager.default.fileExists(atPath: path))
    }

    @Test("respects minimum log level")
    func respectsMinLevel() {
        let path = makeTempPath()
        let logger = FileLogger(filePath: path, minLevel: .warning)
        logger.log(.debug, "should not appear")
        logger.log(.info, "should not appear")
        logger.log(.warning, "should appear")
        logger.waitForPendingWrites()
        let content = try! String(contentsOfFile: path, encoding: .utf8)
        #expect(!content.contains("should not appear"))
        #expect(content.contains("should appear"))
    }

    @Test("log entry format contains timestamp and level")
    func logFormat() {
        let path = makeTempPath()
        let logger = FileLogger(filePath: path, minLevel: .debug)
        logger.log(.error, "test message")
        logger.waitForPendingWrites()
        let content = try! String(contentsOfFile: path, encoding: .utf8)
        #expect(content.contains("[ERROR]"))
        #expect(content.contains("test message"))
        #expect(content.contains("[20")) // ISO8601 year prefix
    }

    @Test("LogLevel.from parses strings correctly")
    func logLevelFromString() {
        #expect(LogLevel.from(string: "debug") == .debug)
        #expect(LogLevel.from(string: "DEBUG") == .debug)
        #expect(LogLevel.from(string: "warning") == .warning)
        #expect(LogLevel.from(string: "warn") == .warning)
        #expect(LogLevel.from(string: "error") == .error)
        #expect(LogLevel.from(string: "info") == .info)
        #expect(LogLevel.from(string: "garbage") == .info)
    }

    @Test("LogLevel comparison works")
    func logLevelComparison() {
        #expect(LogLevel.debug < LogLevel.info)
        #expect(LogLevel.info < LogLevel.warning)
        #expect(LogLevel.warning < LogLevel.error)
    }

    @Test("log() is safe under 20 concurrent calls from a TaskGroup")
    func concurrentLogging() async {
        let path = makeTempPath()
        let logger = FileLogger(filePath: path, minLevel: .debug)
        await withTaskGroup(of: Void.self) { group in
            for i in 0..<20 {
                group.addTask {
                    logger.log(.info, "message \(i)")
                }
            }
        }
        // Drain the serial queue: all async dispatches submitted before this point are done.
        logger.waitForPendingWrites()
        #expect(FileManager.default.fileExists(atPath: path))
        let content = try! String(contentsOfFile: path, encoding: .utf8)
        #expect(!content.isEmpty)

        // Every line must start with a valid ISO8601 timestamp — verifies no
        // partial corruption under concurrent formatter usage.
        let formatter = ISO8601DateFormatter()
        let lines = content.split(separator: "\n")
        #expect(lines.count == 20)
        for line in lines {
            // Format: [2026-04-17T12:00:00Z] [INFO] message N
            guard let open = line.firstIndex(of: "["),
                  let close = line.firstIndex(of: "]") else {
                Issue.record("Missing timestamp brackets in: \(line)")
                continue
            }
            let timestamp = String(line[line.index(after: open)..<close])
            #expect(formatter.date(from: timestamp) != nil, "Invalid ISO8601 timestamp: \(timestamp)")
        }
    }

    // MARK: - purgeEntries

    @Test("purge removes all lines when all are older than cutoff")
    func purgeAllOld() throws {
        let path = makeTempPath()
        let logger = FileLogger(filePath: path, minLevel: .debug)
        let old = ISO8601DateFormatter().string(from: Date(timeIntervalSince1970: 0))
        let line = "[\(old)] [INFO] ancient\n"
        try line.data(using: .utf8)!.write(to: URL(fileURLWithPath: path))
        try logger.purgeEntries(olderThan: Date())
        let content = try String(contentsOfFile: path, encoding: .utf8)
        #expect(content == "")
    }

    @Test("purge keeps all lines when all are newer than cutoff")
    func purgeAllRecent() throws {
        let path = makeTempPath()
        let logger = FileLogger(filePath: path, minLevel: .debug)
        let recent = ISO8601DateFormatter().string(from: Date())
        let original = "[\(recent)] [INFO] fresh\n"
        try original.data(using: .utf8)!.write(to: URL(fileURLWithPath: path))
        try logger.purgeEntries(olderThan: Date(timeIntervalSinceNow: -3600))
        let content = try String(contentsOfFile: path, encoding: .utf8)
        #expect(content == original)
    }

    @Test("purge keeps only recent lines in mixed file")
    func purgeMixed() throws {
        let path = makeTempPath()
        let logger = FileLogger(filePath: path, minLevel: .debug)
        let fmt = ISO8601DateFormatter()
        let old = fmt.string(from: Date(timeIntervalSince1970: 0))
        let recent = fmt.string(from: Date())
        let lines = "[\(old)] [INFO] old\n[\(recent)] [INFO] new\n"
        try lines.data(using: .utf8)!.write(to: URL(fileURLWithPath: path))
        try logger.purgeEntries(olderThan: Date(timeIntervalSinceNow: -3600))
        let content = try String(contentsOfFile: path, encoding: .utf8)
        #expect(content == "[\(recent)] [INFO] new\n")
    }

    @Test("purge handles empty file without crash")
    func purgeEmptyFile() throws {
        let path = makeTempPath()
        let logger = FileLogger(filePath: path, minLevel: .debug)
        FileManager.default.createFile(atPath: path, contents: Data())
        try logger.purgeEntries(olderThan: Date())
    }

    @Test("purge handles missing file without crash")
    func purgeMissingFile() throws {
        let path = makeTempPath()
        let logger = FileLogger(filePath: path, minLevel: .debug)
        // Don't create the file — purge should be a no-op
        try logger.purgeEntries(olderThan: Date())
        #expect(!FileManager.default.fileExists(atPath: path))
    }

    @Test("continuation line following an old entry is dropped")
    func purgeContinuationDropped() throws {
        let path = makeTempPath()
        let logger = FileLogger(filePath: path, minLevel: .debug)
        let old = ISO8601DateFormatter().string(from: Date(timeIntervalSince1970: 0))
        let lines = "[\(old)] [ERROR] crash\n  at SomeClass.method()\n  at main()\n"
        try lines.data(using: .utf8)!.write(to: URL(fileURLWithPath: path))
        try logger.purgeEntries(olderThan: Date())
        let content = try String(contentsOfFile: path, encoding: .utf8)
        #expect(content == "")
    }

    @Test("continuation line following a kept entry is kept")
    func purgeContinuationKept() throws {
        let path = makeTempPath()
        let logger = FileLogger(filePath: path, minLevel: .debug)
        let recent = ISO8601DateFormatter().string(from: Date())
        let original = "[\(recent)] [ERROR] crash\n  at SomeClass.method()\n"
        try original.data(using: .utf8)!.write(to: URL(fileURLWithPath: path))
        try logger.purgeEntries(olderThan: Date(timeIntervalSinceNow: -3600))
        let content = try String(contentsOfFile: path, encoding: .utf8)
        #expect(content == original)
    }

    @Test("purge also cleans rotated backup file")
    func purgeBackupFile() throws {
        let path = makeTempPath()
        let logger = FileLogger(filePath: path, minLevel: .debug)
        let old = ISO8601DateFormatter().string(from: Date(timeIntervalSince1970: 0))
        let recent = ISO8601DateFormatter().string(from: Date())
        try "[\(recent)] [INFO] keep\n".data(using: .utf8)!.write(to: URL(fileURLWithPath: path))
        let backup = path + ".1"
        try "[\(old)] [INFO] discard\n".data(using: .utf8)!.write(to: URL(fileURLWithPath: backup))
        try logger.purgeEntries(olderThan: Date(timeIntervalSinceNow: -3600))
        let backupContent = try String(contentsOfFile: backup, encoding: .utf8)
        #expect(backupContent == "")
    }

    @Test("purge concurrent with log() does not corrupt file")
    func purgeConcurrentWithLog() async throws {
        let path = makeTempPath()
        let logger = FileLogger(filePath: path, minLevel: .debug)
        // Seed the file with a recent line so purge has something to examine
        logger.log(.info, "seed")
        logger.waitForPendingWrites()

        let cutoff = Date(timeIntervalSinceNow: -3600)
        await withTaskGroup(of: Void.self) { group in
            for i in 0..<20 {
                group.addTask { logger.log(.info, "msg \(i)") }
            }
            group.addTask {
                do {
                    try logger.purgeEntries(olderThan: cutoff)
                } catch {
                    Issue.record("Concurrent purge threw: \(error)")
                }
            }
        }
        logger.waitForPendingWrites()

        let content = try String(contentsOfFile: path, encoding: .utf8)
        let formatter = ISO8601DateFormatter()
        for line in content.split(separator: "\n") {
            guard let open = line.firstIndex(of: "["),
                  let close = line[line.index(after: open)...].firstIndex(of: "]") else {
                Issue.record("Missing timestamp brackets in: \(line)")
                continue
            }
            let stamp = String(line[line.index(after: open)..<close])
            #expect(formatter.date(from: stamp) != nil, "Invalid ISO8601: \(stamp)")
        }
    }

    @Test("dynamicLevel overrides static minLevel")
    func dynamicLevelOverride() {
        let path = makeTempPath()
        let levelHolder = MutableLogLevel(.debug)
        let logger = FileLogger(filePath: path, dynamicLevel: { levelHolder.value })

        logger.log(.debug, "should appear")
        logger.waitForPendingWrites()
        let content1 = try! String(contentsOfFile: path, encoding: .utf8)
        #expect(content1.contains("should appear"))

        // Switch dynamic level to error — debug messages should be suppressed
        levelHolder.value = .error
        logger.log(.debug, "should not appear")
        logger.waitForPendingWrites()
        let content2 = try! String(contentsOfFile: path, encoding: .utf8)
        #expect(!content2.contains("should not appear"))
    }

    @Test("effectiveMinLevel returns dynamicLevel when set")
    func effectiveMinLevel() {
        let path = makeTempPath()
        let staticLogger = FileLogger(filePath: path, minLevel: .warning)
        #expect(staticLogger.effectiveMinLevel == .warning)

        let dynamicLogger = FileLogger(filePath: path, dynamicLevel: { .debug })
        #expect(dynamicLogger.effectiveMinLevel == .debug)
    }

    @Test("rotates log file when exceeding max size")
    func rotatesFile() {
        let path = makeTempPath()
        let logger = FileLogger(filePath: path, minLevel: .debug)
        // Write > 5 MB to trigger rotation
        let bigMessage = String(repeating: "X", count: 10_000)
        for _ in 0..<600 {
            logger.log(.info, bigMessage)
        }
        logger.waitForPendingWrites()
        let backup = path + ".1"
        #expect(FileManager.default.fileExists(atPath: backup))
        // Main file should be smaller than backup after rotation
        let mainSize = (try? FileManager.default.attributesOfItem(atPath: path)[.size] as? UInt64) ?? 0
        #expect(mainSize < 5 * 1024 * 1024)
    }

    @Test("purge throws readFailed for unreadable file")
    func purgeReadFailed() throws {
        let path = makeTempPath()
        let logger = FileLogger(filePath: path, minLevel: .debug)
        try "some content".data(using: .utf8)!.write(to: URL(fileURLWithPath: path))
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: path)
        defer {
            do {
                try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: path)
            } catch {
                Issue.record("Failed to restore permissions: \(error)")
            }
        }

        #expect {
            try logger.purgeEntries(olderThan: Date())
        } throws: { error in
            guard let purgeError = error as? LogPurgeError,
                  case .readFailed = purgeError else { return false }
            return true
        }
    }

    @Test("purge keeps line timestamped exactly at cutoff")
    func purgeExactBoundary() throws {
        let path = makeTempPath()
        let logger = FileLogger(filePath: path, minLevel: .debug)
        let fmt = ISO8601DateFormatter()
        let stamp = fmt.string(from: Date())
        // Derive cutoff from the formatted string so both sides share
        // the same second-truncated precision
        let cutoff = fmt.date(from: stamp)!  // known-valid: just formatted
        let original = "[\(stamp)] [INFO] boundary\n"
        try original.data(using: .utf8)!.write(to: URL(fileURLWithPath: path))
        try logger.purgeEntries(olderThan: cutoff)
        let content = try String(contentsOfFile: path, encoding: .utf8)
        #expect(content == original)
    }
}
