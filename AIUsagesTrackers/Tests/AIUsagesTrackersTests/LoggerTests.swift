import Foundation
import Testing
@testable import AIUsagesTrackersLib

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
}
