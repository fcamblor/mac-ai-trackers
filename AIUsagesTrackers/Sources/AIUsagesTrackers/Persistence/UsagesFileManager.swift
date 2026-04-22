import Foundation
import Darwin

public actor UsagesFileManager {
    // Internal init so tests can create isolated instances via @testable import.
    // Production code must use `UsagesFileManager.shared`.
    public static let shared = UsagesFileManager()

    nonisolated public let filePath: String
    nonisolated public let lockPath: String
    private let logger: FileLogger
    private let lockTimeoutSeconds: TimeInterval

    init(
        filePath: String? = nil,
        logger: FileLogger = Loggers.app,
        lockTimeoutSeconds: TimeInterval = 5.0
    ) {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        self.filePath = filePath ?? "\(home)/.cache/ai-usages-tracker/usages.json"
        self.logger = logger
        self.lockPath = self.filePath + ".lock"
        self.lockTimeoutSeconds = lockTimeoutSeconds

        let dir = (self.filePath as NSString).deletingLastPathComponent
        do {
            try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true, attributes: nil)
        } catch {
            logger.log(.error, "Failed to create directory \(dir): \(error)")
        }
    }

    // MARK: - Public

    public func read() async -> UsagesFile {
        do {
            return try await withFileLock(mode: LOCK_SH) { readUnsafe() }
        } catch is CancellationError {
            return UsagesFile()
        } catch {
            logger.log(.warning, "flock read failed — returning empty file: \(error)")
            return UsagesFile()
        }
    }

    public func update(with entries: [VendorUsageEntry]) async {
        await update(with: entries, outagesByVendor: [:])
    }

    /// Applies a usage merge plus per-vendor outage replacement in a single locked read-modify-write.
    ///
    /// Outage policy per vendor key in `outagesByVendor`:
    /// - present, non-empty list → replaces all outages of that vendor
    /// - present, empty list → removes all outages of that vendor ("all clear")
    /// - absent → outages of that vendor are preserved as-is (fetch failed, or no connector for it)
    public func update(
        with entries: [VendorUsageEntry],
        outagesByVendor: [Vendor: [Outage]]
    ) async {
        do {
            try await withFileLock(mode: LOCK_EX) {
                var file = readUnsafe()
                file = merge(existing: file, incoming: entries)
                if !outagesByVendor.isEmpty {
                    file.outages = applyOutageReplacement(
                        existing: file.outages,
                        replacements: outagesByVendor
                    )
                }
                writeUnsafe(file)
            }
        } catch is CancellationError {
            return
        } catch {
            logger.log(.warning, "flock update failed — skipping write: \(error)")
        }
    }

    // MARK: - Active-account update

    public func updateIsActive(vendor: Vendor, activeAccount: AccountEmail?) async {
        do {
            try await withFileLock(mode: LOCK_EX) {
                var file = readUnsafe()
                var changed = false
                for i in file.usages.indices where file.usages[i].vendor == vendor {
                    let newActive = file.usages[i].account == activeAccount
                    if file.usages[i].isActive != newActive {
                        file.usages[i].isActive = newActive
                        changed = true
                    }
                }
                if changed {
                    writeUnsafe(file)
                }
            }
        } catch is CancellationError {
            return
        } catch {
            logger.log(.warning, "flock updateIsActive failed — skipping: \(error)")
        }
    }

    // MARK: - Outage replacement

    /// Replaces outages per-vendor while preserving outages for vendors absent from `replacements`.
    /// Vendors not covered by a status connector (or producers external to this app) keep their
    /// entries untouched, so the file format stays open to multiple producers.
    func applyOutageReplacement(
        existing: [Outage],
        replacements: [Vendor: [Outage]]
    ) -> [Outage] {
        var result = existing.filter { replacements[$0.vendor] == nil }
        for (_, newOutages) in replacements {
            result.append(contentsOf: newOutages)
        }
        return result
    }

    // MARK: - Merge logic

    func merge(existing: UsagesFile, incoming: [VendorUsageEntry]) -> UsagesFile {
        // Usage entries are vendor-keyed upserts; outages are handled separately by
        // `applyOutageReplacement`, which the public `update(with:outagesByVendor:)` runs
        // after this merge. The file format is open to external outage producers for
        // vendors without a status connector.
        var usages = existing.usages
        var indexByKey: [String: Int] = [:]
        for (i, entry) in usages.enumerated() {
            indexByKey["\(entry.vendor.rawValue)|\(entry.account.rawValue)"] = i
        }
        for entry in incoming {
            let key = "\(entry.vendor.rawValue)|\(entry.account.rawValue)"
            if let idx = indexByKey[key] {
                if entry.lastError != nil {
                    // Errors must not erase previously acquired data: the file may hold good
                    // metrics from a prior successful fetch while the connector's in-memory
                    // lastKnownMetrics is empty (e.g. after an app restart).
                    var merged = entry
                    if merged.metrics.isEmpty {
                        merged.metrics = usages[idx].metrics
                    }
                    if merged.lastAcquiredOn == nil {
                        merged.lastAcquiredOn = usages[idx].lastAcquiredOn
                    }
                    usages[idx] = merged
                } else {
                    usages[idx] = entry
                }
            } else {
                indexByKey[key] = usages.count
                usages.append(entry)
            }
        }

        return UsagesFile(usages: usages, outages: existing.outages)
    }

    // MARK: - Lock-guarded internals

    /// Acquires an advisory flock on the dedicated lock file, runs `body`, then releases.
    /// Uses a separate lock file because atomic writes replace the JSON inode, making
    /// flock on the data file itself ineffective for protecting external readers.
    private func withFileLock<T>(mode: Int32, body: () throws -> T) async throws -> T {
        let fd = Darwin.open(lockPath, O_CREAT | O_RDWR, 0o644)
        guard fd >= 0 else { throw FileManagerError.cannotOpenLockFile(path: lockPath) }
        defer { Darwin.close(fd) }

        let deadline = Date().addingTimeInterval(lockTimeoutSeconds)
        while flock(fd, mode | LOCK_NB) != 0 {
            guard Date() < deadline else {
                throw FileManagerError.lockTimeout(path: lockPath, timeoutSeconds: lockTimeoutSeconds)
            }
            try await Task.sleep(for: .milliseconds(50))
        }
        defer { flock(fd, LOCK_UN) }

        return try body()
    }

    // MARK: - Unsafe (actor-isolated, no external lock needed)

    private func readUnsafe() -> UsagesFile {
        guard let data = FileManager.default.contents(atPath: filePath) else {
            return UsagesFile()
        }
        do {
            return try JSONDecoder().decode(UsagesFile.self, from: data)
        } catch {
            logger.log(.error, "Failed to decode \(filePath): \(error)")
            return UsagesFile()
        }
    }

    private func writeUnsafe(_ file: UsagesFile) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(file) else {
            logger.log(.error, "Failed to encode usages file")
            return
        }
        do {
            try data.write(to: URL(fileURLWithPath: filePath), options: .atomic)
        } catch {
            logger.log(.error, "Atomic write failed: \(error)")
            return
        }
        logger.log(.debug, "Wrote usages file to \(filePath)")
    }
}

enum FileManagerError: Error, CustomStringConvertible {
    case cannotOpenLockFile(path: String)
    case lockTimeout(path: String, timeoutSeconds: Double)

    var description: String {
        switch self {
        case let .cannotOpenLockFile(path):
            "Cannot open lock file at \(path)"
        case let .lockTimeout(path, secs):
            "Could not acquire flock on \(path) within \(secs)s"
        }
    }
}
