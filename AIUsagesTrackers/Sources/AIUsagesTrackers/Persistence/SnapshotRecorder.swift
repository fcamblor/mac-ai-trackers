import Foundation
import CryptoKit

public protocol SnapshotRecording: Sendable {
    func recordSnapshot(from file: UsagesFile, now: Date) async
}

/// Append-only daily JSONL recorder for usage-history snapshots.
///
/// Writes one line per tick into
/// `{rootPath}/{year}/{month}/{year}-{month}-{day}.jsonl`, where each line is a
/// `TickSnapshot` carrying every vendor/account/metric captured at that instant.
/// Day boundaries are computed in UTC so the file name always matches the UTC
/// date embedded in each line's timestamp — the calendar is injectable for tests.
public actor SnapshotRecorder: SnapshotRecording {
    public nonisolated let rootPath: String
    private let logger: FileLogger
    private let fileManager: FileManager
    private let calendar: Calendar

    /// SHA256 of the last payload written to disk (excluding timestamp), used to
    /// skip ticks whose content is identical to the previous one. Lazily seeded
    /// from the last line of today's file on the first tick after a process
    /// restart so dedup survives restarts.
    private var lastWrittenHash: String?
    private var didSeedHashFromDisk: Bool = false

    /// Pass a custom `calendar` to override the UTC default (e.g. in tests that
    /// need a specific fixed-timezone calendar). Pass `nil` (the default) to get
    /// UTC, which keeps the file-name date consistent with the UTC timestamps
    /// embedded in each JSONL line.
    public init(
        rootPath: String? = nil,
        logger: FileLogger = Loggers.app,
        fileManager: FileManager = .default,
        calendar: Calendar? = nil
    ) {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        self.rootPath = rootPath ?? "\(home)/.cache/ai-usages-tracker/usage-history"
        self.logger = logger
        self.fileManager = fileManager
        if let calendar {
            self.calendar = calendar
        } else {
            var utc = Calendar(identifier: .gregorian)
            utc.timeZone = TimeZone(identifier: "UTC")!
            self.calendar = utc
        }
    }

    public func recordSnapshot(from file: UsagesFile, now: Date = Date()) async {
        let accounts = Self.flatten(usages: file.usages, now: now)
        guard !accounts.isEmpty else {
            logger.log(.debug, "SnapshotRecorder: no metrics to snapshot — skipping tick")
            return
        }

        let hash: String
        do {
            hash = try Self.hash(of: accounts)
        } catch {
            logger.log(.error, "SnapshotRecorder: failed to encode payload for hashing: \(error)")
            return
        }

        if !didSeedHashFromDisk {
            lastWrittenHash = lastHashOnDisk(for: now) ?? lastWrittenHash
            didSeedHashFromDisk = true
        }

        if hash == lastWrittenHash {
            logger.log(.debug, "SnapshotRecorder: tick unchanged — skipping")
            return
        }

        let snapshot = TickSnapshot(timestamp: ISODate(date: now), accounts: accounts)
        let line: Data
        do {
            line = try Self.encode(snapshot)
        } catch {
            logger.log(.error, "SnapshotRecorder: failed to encode snapshot: \(error)")
            return
        }

        let targetURL: URL
        do {
            targetURL = try prepareDailyFile(for: now)
        } catch {
            logger.log(.error, "SnapshotRecorder: failed to prepare daily file: \(error)")
            return
        }

        do {
            try append(line: line, to: targetURL)
        } catch {
            logger.log(.error, "SnapshotRecorder: append failed at \(targetURL.path): \(error)")
            return
        }

        lastWrittenHash = hash
        logger.log(.info, "SnapshotRecorder: appended 1 tick (\(accounts.count) account(s)) to \(targetURL.path)")
    }

    // MARK: - Helpers

    static func flatten(usages: [VendorUsageEntry], now: Date) -> [AccountSnapshot] {
        var out: [AccountSnapshot] = []
        for entry in usages {
            var metrics: [MetricSnapshot] = []
            for metric in entry.metrics {
                switch metric {
                case let .timeWindow(name, resetAt, _, usagePercent):
                    metrics.append(MetricSnapshot(
                        name: name,
                        kind: .timeWindow,
                        usagePercent: isOutdated(resetAt: resetAt, now: now) ? nil : usagePercent
                    ))
                case let .payAsYouGo(name, amount, currency):
                    metrics.append(MetricSnapshot(
                        name: name,
                        kind: .payAsYouGo,
                        currentAmount: amount,
                        currency: currency
                    ))
                case .unknown:
                    // Forward-compatibility placeholder — no payload to record.
                    continue
                }
            }
            if !metrics.isEmpty {
                out.append(AccountSnapshot(vendor: entry.vendor, account: entry.account, metrics: metrics))
            }
        }
        return out
    }

    private static func isOutdated(resetAt: ISODate?, now: Date) -> Bool {
        guard let resetDate = resetAt?.date else {
            return false
        }
        return resetDate <= now
    }

    /// Computes the canonical SHA256 hash of the accounts payload. Canonicalization
    /// uses sorted JSON keys so logically-equal payloads always hash identically,
    /// regardless of the recorder's struct-field ordering.
    static func hash(of accounts: [AccountSnapshot]) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(accounts)
        let digest = SHA256.hash(data: data)
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    /// Encodes the line for the JSONL file with `timestamp` written before
    /// `accounts`. JSONEncoder gives no ordering guarantee on synthesized
    /// keyed containers (Apple has historically alphabetized keys), so we
    /// assemble the top-level object by hand to keep the file readable.
    static func encode(_ snapshot: TickSnapshot) throws -> Data {
        let encoder = JSONEncoder()
        let timestampData = try encoder.encode(snapshot.timestamp)
        let accountsData = try encoder.encode(snapshot.accounts)

        var data = Data()
        data.append(openBraceByte)
        data.append(Data("\"timestamp\":".utf8))
        data.append(timestampData)
        data.append(Data(",\"accounts\":".utf8))
        data.append(accountsData)
        data.append(closeBraceByte)
        return data
    }

    private func dailyFileURL(for date: Date) -> URL {
        let components = calendar.dateComponents([.year, .month, .day], from: date)
        let year = String(format: "%04d", components.year ?? 0)
        let month = String(format: "%02d", components.month ?? 0)
        let day = String(format: "%02d", components.day ?? 0)
        return URL(fileURLWithPath: rootPath)
            .appendingPathComponent(year, isDirectory: true)
            .appendingPathComponent(month, isDirectory: true)
            .appendingPathComponent("\(year)-\(month)-\(day).jsonl")
    }

    private func prepareDailyFile(for date: Date) throws -> URL {
        let url = dailyFileURL(for: date)
        try fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        return url
    }

    /// Reads the last JSONL line of today's file (if any) and returns its payload
    /// hash. Used to seed dedup after a process restart so the very first tick
    /// after launch doesn't append a line identical to what's already on disk.
    private func lastHashOnDisk(for date: Date) -> String? {
        let url = dailyFileURL(for: date)
        guard fileManager.fileExists(atPath: url.path),
              let data = try? Data(contentsOf: url),
              let lineData = Self.lastLineData(in: data) else {
            return nil
        }
        do {
            let tick = try JSONDecoder().decode(TickSnapshot.self, from: lineData)
            return try Self.hash(of: tick.accounts)
        } catch {
            logger.log(.warning, "SnapshotRecorder: cannot parse last line of \(url.path): \(error)")
            return nil
        }
    }

    /// Returns the byte range of the last non-empty newline-terminated line.
    static func lastLineData(in data: Data) -> Data? {
        var end = data.count
        while end > 0, data[end - 1] == Self.newlineByte { end -= 1 }
        guard end > 0 else { return nil }
        var start = end
        while start > 0, data[start - 1] != Self.newlineByte { start -= 1 }
        return data.subdata(in: start..<end)
    }

    private func append(line: Data, to url: URL) throws {
        var payload = line
        payload.append(Self.newlineByte)

        if !fileManager.fileExists(atPath: url.path) {
            // createFile returns false if the path is unwritable; surface that as an error
            // instead of letting the subsequent FileHandle open throw a more cryptic one.
            guard fileManager.createFile(atPath: url.path, contents: nil) else {
                throw SnapshotRecorderError.cannotCreateFile(path: url.path)
            }
        }

        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: payload)
    }

    private static let newlineByte: UInt8 = 0x0A
    private static let openBraceByte: UInt8 = 0x7B
    private static let closeBraceByte: UInt8 = 0x7D
}

public enum SnapshotRecorderError: Error, CustomStringConvertible {
    case cannotCreateFile(path: String)

    public var description: String {
        switch self {
        case let .cannotCreateFile(path): "Cannot create snapshot file at \(path)"
        }
    }
}
