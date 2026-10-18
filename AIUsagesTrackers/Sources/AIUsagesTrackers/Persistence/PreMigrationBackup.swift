import Foundation

public enum PreMigrationBackupError: Error, Equatable {
    case createDirectoryFailed(path: String, underlying: String)
    case writeFailed(path: String, underlying: String)
    case copyFailed(source: String, destination: String, underlying: String)
    case missingBackup(path: String)
    case unreadablePreferences(path: String, underlying: String)
    case restoreFileFailed(path: String, underlying: String)
}

/// Snapshot of the app-owned state taken right before a storage migration, so
/// a user downgrading to the previous release can put the pre-migration data
/// back. Covers the `ai-tracker.*` preferences and the app's top-level cache
/// files that a migration may rewrite. The append-only usage history is not
/// copied: migrations never rewrite it.
public struct PreMigrationBackup: Sendable {
    /// Relative to the app cache directory.
    public static let migrationTo080DirectoryName = "backuped-files/migration-to-0.8"
    static let preferencesFileName = "preferences.plist"
    static let manifestFileName = "manifest.json"
    private static let preferenceKeyPrefix = "ai-tracker."

    public let directory: URL
    /// Absolute paths of the cache files to snapshot (restored to the same path).
    public let files: [URL]

    public init(directory: URL, files: [URL]) {
        self.directory = directory
        self.files = files
    }

    /// Backup of the cache files a 0.7.x → 0.8 migration touches.
    public static func migrationTo080(cacheDir: String = Loggers.cacheDir) -> PreMigrationBackup {
        let cache = URL(fileURLWithPath: cacheDir)
        return PreMigrationBackup(
            directory: cache.appendingPathComponent(migrationTo080DirectoryName),
            files: [
                cache.appendingPathComponent("usages.json"),
                cache.appendingPathComponent(StartupMigrationRunner.defaultFileName),
            ]
        )
    }

    private struct Manifest: Codable {
        let createdAt: ISODate
        /// File names (within `directory`) that existed and were copied.
        /// Files absent at backup time are removed again on restore.
        let backedUpFiles: [String]
    }

    public func exists(fileManager: FileManager = .default) -> Bool {
        fileManager.fileExists(atPath: directory.appendingPathComponent(Self.manifestFileName).path)
    }

    /// Writes the snapshot, replacing any previous one in `directory`.
    public func create(
        defaults: UserDefaults,
        fileManager: FileManager = .default,
        now: Date = Date()
    ) throws {
        do {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            throw PreMigrationBackupError.createDirectoryFailed(path: directory.path, underlying: "\(error)")
        }

        let preferences = defaults.dictionaryRepresentation()
            .filter { $0.key.hasPrefix(Self.preferenceKeyPrefix) }
        let preferencesURL = directory.appendingPathComponent(Self.preferencesFileName)
        do {
            let data = try PropertyListSerialization.data(fromPropertyList: preferences, format: .binary, options: 0)
            try data.write(to: preferencesURL, options: .atomic)
        } catch {
            throw PreMigrationBackupError.writeFailed(path: preferencesURL.path, underlying: "\(error)")
        }

        var backedUp: [String] = []
        for file in files where fileManager.fileExists(atPath: file.path) {
            let destination = directory.appendingPathComponent(file.lastPathComponent)
            guard let data = fileManager.contents(atPath: file.path) else {
                throw PreMigrationBackupError.copyFailed(source: file.path, destination: destination.path, underlying: "unreadable")
            }
            do {
                try data.write(to: destination, options: .atomic)
            } catch {
                throw PreMigrationBackupError.copyFailed(source: file.path, destination: destination.path, underlying: "\(error)")
            }
            backedUp.append(file.lastPathComponent)
        }

        // Written last: its presence is what marks the backup as complete.
        let manifestURL = directory.appendingPathComponent(Self.manifestFileName)
        do {
            let data = try JSONEncoder().encode(Manifest(createdAt: ISODate(date: now), backedUpFiles: backedUp))
            try data.write(to: manifestURL, options: .atomic)
        } catch {
            throw PreMigrationBackupError.writeFailed(path: manifestURL.path, underlying: "\(error)")
        }
    }

    /// Puts the snapshot back: every current `ai-tracker.*` preference is
    /// replaced by the backed-up set, and each cache file is restored (or
    /// removed when it did not exist at backup time). Callers must stop every
    /// writer (poller, snapshot scheduler) first and quit right after.
    public func restore(defaults: UserDefaults, fileManager: FileManager = .default) throws {
        let manifestURL = directory.appendingPathComponent(Self.manifestFileName)
        guard let manifestData = fileManager.contents(atPath: manifestURL.path) else {
            throw PreMigrationBackupError.missingBackup(path: manifestURL.path)
        }
        let manifest: Manifest
        do {
            manifest = try JSONDecoder().decode(Manifest.self, from: manifestData)
        } catch {
            throw PreMigrationBackupError.unreadablePreferences(path: manifestURL.path, underlying: "\(error)")
        }

        let preferencesURL = directory.appendingPathComponent(Self.preferencesFileName)
        let preferences: [String: Any]
        do {
            let data = try Data(contentsOf: preferencesURL)
            guard let decoded = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else {
                throw PreMigrationBackupError.unreadablePreferences(path: preferencesURL.path, underlying: "not a dictionary")
            }
            preferences = decoded
        } catch let error as PreMigrationBackupError {
            throw error
        } catch {
            throw PreMigrationBackupError.unreadablePreferences(path: preferencesURL.path, underlying: "\(error)")
        }

        // Files first: if one fails, preferences are still the migrated ones
        // and the 0.8 app keeps working.
        for file in files {
            let name = file.lastPathComponent
            if manifest.backedUpFiles.contains(name) {
                let source = directory.appendingPathComponent(name)
                guard let data = fileManager.contents(atPath: source.path) else {
                    throw PreMigrationBackupError.restoreFileFailed(path: source.path, underlying: "unreadable")
                }
                do {
                    try data.write(to: file, options: .atomic)
                } catch {
                    throw PreMigrationBackupError.restoreFileFailed(path: file.path, underlying: "\(error)")
                }
            } else if fileManager.fileExists(atPath: file.path) {
                do {
                    try fileManager.removeItem(at: file)
                } catch {
                    throw PreMigrationBackupError.restoreFileFailed(path: file.path, underlying: "\(error)")
                }
            }
        }

        for key in defaults.dictionaryRepresentation().keys where key.hasPrefix(Self.preferenceKeyPrefix) {
            defaults.removeObject(forKey: key)
        }
        for (key, value) in preferences {
            defaults.set(value, forKey: key)
        }
    }
}
