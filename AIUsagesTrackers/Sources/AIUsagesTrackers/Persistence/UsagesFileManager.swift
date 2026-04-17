import Foundation

public actor UsagesFileManager {
    // Internal init so tests can create isolated instances via @testable import.
    // Production code must use `UsagesFileManager.shared`.
    public static let shared = UsagesFileManager()

    nonisolated public let filePath: String
    private let logger: FileLogger

    init(
        filePath: String? = nil,
        logger: FileLogger = Loggers.app
    ) {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        self.filePath = filePath ?? "\(home)/.cache/ai-usages-tracker/usages.json"
        self.logger = logger

        let dir = (self.filePath as NSString).deletingLastPathComponent
        do {
            try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true, attributes: nil)
        } catch {
            logger.log(.error, "Failed to create directory \(dir): \(error)")
        }
    }

    // MARK: - Public

    public func read() -> UsagesFile {
        readUnsafe()
    }

    public func update(with entries: [VendorUsageEntry]) {
        var file = readUnsafe()
        file = merge(existing: file, incoming: entries)
        writeUnsafe(file)
    }

    // MARK: - Active-account update

    public func updateIsActive(vendor: String, activeAccount: String?) {
        var file = readUnsafe()
        var changed = false
        for i in file.usages.indices {
            guard file.usages[i].vendor == vendor else { continue }
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

    // MARK: - Merge logic

    public func merge(existing: UsagesFile, incoming: [VendorUsageEntry]) -> UsagesFile {
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
