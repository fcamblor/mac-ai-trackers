import Foundation
import Darwin

/// Persists `StatusComponentsCache` to a JSON file alongside the usages
/// cache. Uses a dedicated lock file so atomic writes (which replace the
/// inode) do not invalidate flock-based reader synchronization.
public actor StatusComponentsFileManager {
    public static let shared = StatusComponentsFileManager()

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
        self.filePath = filePath ?? "\(home)/.cache/ai-usages-tracker/status-components.json"
        self.logger = logger
        self.lockPath = self.filePath + ".lock"
        self.lockTimeoutSeconds = lockTimeoutSeconds

        let dir = (self.filePath as NSString).deletingLastPathComponent
        do {
            try FileManager.default.createDirectory(
                atPath: dir, withIntermediateDirectories: true, attributes: nil
            )
        } catch {
            logger.log(.error, "Failed to create status-components cache directory \(dir): \(error)")
        }
    }

    public func read() async -> StatusComponentsCache {
        do {
            return try await withFileLock(mode: LOCK_SH) { readUnsafe() }
        } catch is CancellationError {
            return StatusComponentsCache()
        } catch {
            logger.log(.warning, "flock read failed on status-components — returning empty: \(error)")
            return StatusComponentsCache()
        }
    }

    public func upsert(_ entry: StatusComponentsCacheEntry) async {
        do {
            try await withFileLock(mode: LOCK_EX) {
                var cache = readUnsafe()
                cache.upsert(entry)
                writeUnsafe(cache)
            }
        } catch is CancellationError {
            return
        } catch {
            logger.log(.warning, "flock upsert failed on status-components: \(error)")
        }
    }

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

    private func readUnsafe() -> StatusComponentsCache {
        guard let data = FileManager.default.contents(atPath: filePath) else {
            return StatusComponentsCache()
        }
        do {
            return try JSONDecoder().decode(StatusComponentsCache.self, from: data)
        } catch {
            logger.log(.error, "Failed to decode \(filePath): \(error)")
            return StatusComponentsCache()
        }
    }

    private func writeUnsafe(_ cache: StatusComponentsCache) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(cache) else {
            logger.log(.error, "Failed to encode status-components cache")
            return
        }
        do {
            try data.write(to: URL(fileURLWithPath: filePath), options: .atomic)
        } catch {
            logger.log(.error, "Atomic write failed on status-components: \(error)")
            return
        }
        logger.log(.debug, "Wrote status-components cache to \(filePath)")
    }
}
