import Foundation

final class UsagesFileManager: Sendable {
    let filePath: String
    let lockPath: String
    private let logger: FileLogger

    init(
        filePath: String? = nil,
        logger: FileLogger = Loggers.app
    ) {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        self.filePath = filePath ?? "\(home)/.cache/ai-usages-tracker/usages.json"
        self.lockPath = self.filePath + ".lock"
        self.logger = logger

        let dir = (self.filePath as NSString).deletingLastPathComponent
        do {
            try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true, attributes: nil)
        } catch {
            logger.log(.error, "Failed to create directory \(dir): \(error)")
        }
    }

    // MARK: - Public

    func read() -> UsagesFile {
        withFlockShared {
            readUnsafe()
        } ?? UsagesFile()
    }

    func update(with entries: [VendorUsageEntry]) {
        let success = withFlockExclusive {
            var file = readUnsafe()
            file = merge(existing: file, incoming: entries)
            writeUnsafe(file)
        }
        if !success {
            logger.log(.error, "update(with:) skipped — failed to acquire exclusive flock")
        }
    }

    // MARK: - Merge logic

    func merge(existing: UsagesFile, incoming: [VendorUsageEntry]) -> UsagesFile {
        var usages = existing.usages
        var indexByKey: [String: Int] = [:]
        for (i, entry) in usages.enumerated() {
            indexByKey["\(entry.vendor)|\(entry.account)"] = i
        }
        for entry in incoming {
            let key = "\(entry.vendor)|\(entry.account)"
            if let idx = indexByKey[key] {
                usages[idx] = entry
            } else {
                indexByKey[key] = usages.count
                usages.append(entry)
            }
        }
        return UsagesFile(usages: usages)
    }

    // MARK: - Unsafe (caller holds lock)

    private func readUnsafe() -> UsagesFile {
        guard let data = FileManager.default.contents(atPath: filePath) else {
            return UsagesFile()
        }
        do {
            let decoder = JSONDecoder()
            return try decoder.decode(UsagesFile.self, from: data)
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

    // MARK: - POSIX flock

    private func withFlockShared<T>(_ body: () -> T) -> T? {
        withFlock(operation: LOCK_SH, body)
    }

    @discardableResult
    private func withFlockExclusive(_ body: () -> Void) -> Bool {
        withFlock(operation: LOCK_EX, body) != nil
    }

    private func withFlock<T>(operation: Int32, _ body: () -> T) -> T? {
        let fd = open(lockPath, O_RDWR | O_CREAT, 0o644)
        guard fd >= 0 else {
            logger.log(.error, "Cannot open lock file \(lockPath)")
            return nil
        }
        defer {
            flock(fd, LOCK_UN)
            close(fd)
        }

        guard flock(fd, operation) == 0 else {
            logger.log(.error, "flock failed on \(lockPath)")
            return nil
        }

        logger.log(.debug, "Acquired flock(\(operation == LOCK_SH ? "SH" : "EX")) on \(lockPath)")
        return body()
    }
}
