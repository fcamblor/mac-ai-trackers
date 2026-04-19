import Foundation

public enum LogPurgeError: Error {
    case readFailed(path: String, underlying: any Error)
    case writeFailed(path: String, underlying: any Error)
}

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

    // MARK: - Purge

    /// Removes log lines whose leading ISO 8601 timestamp is older than `cutoff`.
    /// Lines without a parseable timestamp (continuation / malformed) follow the
    /// fate of the preceding timestamped line.
    ///
    /// **Must not** be called from within `queue` — it dispatches synchronously
    /// to `queue` internally and would deadlock.
    public func purgeEntries(olderThan cutoff: Date) throws {
        var captured: (any Error)?
        queue.sync {
            do {
                try self.purgeFile(atPath: self.filePath, cutoff: cutoff)
                let backup = self.filePath + ".1"
                if FileManager.default.fileExists(atPath: backup) {
                    try self.purgeFile(atPath: backup, cutoff: cutoff)
                }
            } catch {
                captured = error
            }
        }
        if let captured { throw captured }
    }

    // MARK: - Private

    private func purgeFile(atPath path: String, cutoff: Date) throws {
        guard FileManager.default.fileExists(atPath: path) else { return }

        let original: String
        do {
            // WHY: reading into memory is acceptable — rotation caps files at 5 MB
            original = try String(contentsOfFile: path, encoding: .utf8)
        } catch {
            throw LogPurgeError.readFailed(path: path, underlying: error)
        }

        let formatter = ISO8601DateFormatter()
        let lines = original.split(separator: "\n", omittingEmptySubsequences: false)
        var kept: [Substring] = []
        var keepingContinuation = true

        for line in lines {
            if let date = parseLeadingTimestamp(from: line, formatter: formatter) {
                if date >= cutoff {
                    kept.append(line)
                    keepingContinuation = true
                } else {
                    keepingContinuation = false
                }
            } else {
                // Continuation / malformed line — follows fate of preceding timestamped line
                if keepingContinuation {
                    kept.append(line)
                }
            }
        }

        let result = kept.joined(separator: "\n")
        guard result != original else { return }

        let url = URL(fileURLWithPath: path)
        guard let data = result.data(using: .utf8) else {
            throw LogPurgeError.writeFailed(
                path: path,
                underlying: NSError(domain: "FileLogger", code: -1, userInfo: [
                    NSLocalizedDescriptionKey: "UTF-8 encoding round-trip failed"
                ])
            )
        }
        do {
            try data.write(to: url, options: .atomic)
        } catch {
            throw LogPurgeError.writeFailed(path: path, underlying: error)
        }
    }

    private func parseLeadingTimestamp(from line: Substring, formatter: ISO8601DateFormatter) -> Date? {
        guard let open = line.firstIndex(of: "["),
              let close = line[line.index(after: open)...].firstIndex(of: "]") else {
            return nil
        }
        let stamp = String(line[line.index(after: open)..<close])
        return formatter.date(from: stamp)
    }

    private func append(level: LogLevel, message: String) {
        queue.async { [self] in
            // Per-call allocation — ISO8601DateFormatter is not thread-safe;
            // acceptable here because logging is a cold path
            let timestamp = ISO8601DateFormatter().string(from: Date())
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

    public static let managed: [FileLogger] = [app, claude]
}
