import Foundation

public actor StartupMigrationRunner {
    public static let defaultFileName = "migrations.json"

    private static let removeUnknownAccountsMigrationID = "remove-account-unknown-placeholders"

    private let fileManager: UsagesFileManager
    private let migrationsFilePath: String
    private let logger: FileLogger
    private let now: @Sendable () -> Date

    public init(
        fileManager: UsagesFileManager = .shared,
        migrationsFilePath: String? = nil,
        logger: FileLogger = Loggers.app,
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let cacheDir = "\(home)/.cache/ai-usages-tracker"
        self.fileManager = fileManager
        self.migrationsFilePath = migrationsFilePath ?? "\(cacheDir)/\(Self.defaultFileName)"
        self.logger = logger
        self.now = now
    }

    public func run() async {
        var file = readMigrationsFile()
        guard !file.hasApplied(Self.removeUnknownAccountsMigrationID) else {
            logger.log(.debug, "Startup migration already applied: \(Self.removeUnknownAccountsMigrationID)")
            return
        }

        guard await fileManager.removeAccountUnknownPlaceholders() else {
            logger.log(.warning, "Startup migration failed: \(Self.removeUnknownAccountsMigrationID)")
            return
        }

        file.applied.append(AppliedStartupMigration(
            id: Self.removeUnknownAccountsMigrationID,
            appliedAt: ISODate(date: now())
        ))
        writeMigrationsFile(file)
        logger.log(.info, "Startup migration applied: \(Self.removeUnknownAccountsMigrationID)")
    }

    private func readMigrationsFile() -> StartupMigrationsFile {
        guard let data = FileManager.default.contents(atPath: migrationsFilePath) else {
            return StartupMigrationsFile()
        }
        do {
            return try JSONDecoder().decode(StartupMigrationsFile.self, from: data)
        } catch {
            logger.log(.warning, "Failed to decode \(migrationsFilePath); rebuilding migrations file: \(error)")
            return StartupMigrationsFile()
        }
    }

    private func writeMigrationsFile(_ file: StartupMigrationsFile) {
        let dir = (migrationsFilePath as NSString).deletingLastPathComponent
        do {
            try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        } catch {
            logger.log(.error, "Failed to create migrations directory \(dir): \(error)")
            return
        }

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        do {
            let data = try encoder.encode(file)
            try data.write(to: URL(fileURLWithPath: migrationsFilePath), options: .atomic)
        } catch {
            logger.log(.error, "Failed to write migrations file \(migrationsFilePath): \(error)")
        }
    }
}

public struct StartupMigrationsFile: Codable, Equatable, Sendable {
    public var applied: [AppliedStartupMigration]

    public init(applied: [AppliedStartupMigration] = []) {
        self.applied = applied
    }

    public func hasApplied(_ id: String) -> Bool {
        applied.contains { $0.id == id }
    }
}

public struct AppliedStartupMigration: Codable, Equatable, Sendable {
    public let id: String
    public let appliedAt: ISODate

    public init(id: String, appliedAt: ISODate) {
        self.id = id
        self.appliedAt = appliedAt
    }
}
