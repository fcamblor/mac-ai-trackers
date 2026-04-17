import Foundation

public enum LogLevel: Int, Comparable, Sendable {
    case debug = 0, info, warning, error

    public static func < (lhs: LogLevel, rhs: LogLevel) -> Bool { lhs.rawValue < rhs.rawValue }

    var label: String {
        switch self {
        case .debug: "DEBUG"
        case .info: "INFO"
        case .warning: "WARN"
        case .error: "ERROR"
        }
    }

    public static func from(string: String) -> LogLevel {
        switch string.lowercased() {
        case "debug": .debug
        case "warning", "warn": .warning
        case "error": .error
        default: .info
        }
    }
}

public final class FileLogger: Sendable {
    public let filePath: String
    public let minLevel: LogLevel
    private let maxBytes: UInt64 = 5 * 1024 * 1024
    private nonisolated(unsafe) static let isoFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        return f
    }()
    private let queue = DispatchQueue(label: "FileLogger.serialQueue")

    public init(filePath: String, minLevel: LogLevel = .info) {
        self.filePath = filePath
        self.minLevel = minLevel
        let dir = (filePath as NSString).deletingLastPathComponent
        do {
            try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true, attributes: nil)
        } catch {
            fputs("FileLogger: cannot create log directory \(dir): \(error)\n", stderr)
        }
    }

    public func log(_ level: LogLevel, _ message: String) {
        guard level >= minLevel else { return }
        append(level: level, message: message)
    }

    /// Blocks until all previously submitted log entries have been written to disk.
    /// Intended for tests that inspect log file contents after calling `log()`.
    func waitForPendingWrites() {
        queue.sync {}
    }

    // MARK: - Private

    private func append(level: LogLevel, message: String) {
        queue.async { [self] in
            let timestamp = Self.isoFormatter.string(from: Date())
            let entry = "[\(timestamp)] [\(level.label)] \(message)\n"
            guard let data = entry.data(using: .utf8) else { return }
            if !FileManager.default.fileExists(atPath: self.filePath) {
                FileManager.default.createFile(atPath: self.filePath, contents: nil)
            }

            self.rotateIfNeeded()

            guard let handle = FileHandle(forWritingAtPath: self.filePath) else { return }
            defer { handle.closeFile() }
            handle.seekToEndOfFile()
            handle.write(data)
        }
    }

    private func rotateIfNeeded() {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: filePath),
              let size = attrs[.size] as? UInt64,
              size > maxBytes else { return }
        let backup = filePath + ".1"
        try? FileManager.default.removeItem(atPath: backup)
        do {
            try FileManager.default.moveItem(atPath: filePath, toPath: backup)
        } catch {
            fputs("FileLogger: rotation failed for \(filePath): \(error)\n", stderr)
        }
        FileManager.default.createFile(atPath: filePath, contents: nil)
    }
}

// MARK: - Shared loggers

public enum Loggers {
    private static let cacheDir: String = {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return "\(home)/.cache/ai-usages-tracker"
    }()

    private static let level: LogLevel = {
        LogLevel.from(string: ProcessInfo.processInfo.environment["AI_TRACKER_LOG_LEVEL"] ?? "info")
    }()

    public static let app = FileLogger(filePath: "\(cacheDir)/app.log", minLevel: level)
    public static let claude = FileLogger(filePath: "\(cacheDir)/claude-usages-connector.log", minLevel: level)
}
