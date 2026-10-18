import Foundation

/// A single Claude Desktop Electron profile directory and the raw material the
/// credential locator needs from it. The encrypted token cache is surfaced
/// verbatim — decryption (which needs the Keychain Safe Storage key) is the
/// locator's job, so this type performs no secret access and triggers no
/// Keychain prompt.
public struct ClaudeDesktopProfile: Sendable, Equatable {
    /// Human-facing label — the profile directory's last path component
    /// (`Claude`, `Claude-3p`, `Dentalsoft`, …). Stable across runs, which
    /// makes it a sound account-identity component for the merge.
    public let name: String
    public let directoryPath: String
    /// Base64 `v10` value of `config.json`'s `oauth:tokenCacheV2` key, or nil
    /// when the profile has never signed in.
    public let encryptedTokenCache: String?

    public init(name: String, directoryPath: String, encryptedTokenCache: String?) {
        self.name = name
        self.directoryPath = directoryPath
        self.encryptedTokenCache = encryptedTokenCache
    }
}

/// Discovers Claude Desktop profile directories and reads their `config.json`.
/// Read-only: it opens `config.json` for reading and never writes, and it never
/// touches the Keychain. Not `Sendable` because it holds a `FileManager`; it is
/// only ever used from within the credential locator / connector actors.
public struct ClaudeDesktopProfileStore {
    /// The two profile directories the Claude Desktop installer always creates
    /// on a machine where the app runs, relative to the user's home. `Claude-3p`
    /// is the secondary ("3p") profile the app provisions alongside the default.
    public static let standardRelativePaths = [
        "Library/Application Support/Claude",
        "Library/Application Support/Claude-3p",
    ]
    public static let tokenCacheConfigKey = "oauth:tokenCacheV2"
    private static let configFileName = "config.json"

    private let fileManager: FileManager
    private let homeDirectoryPath: String
    /// Extra profile directories the user opened via
    /// `--user-data-dir=<path>`, surfaced from preferences. Absolute paths.
    private let customProfilePaths: @Sendable () -> [String]

    public init(
        fileManager: FileManager = .default,
        homeDirectoryPath: String? = nil,
        customProfilePaths: @escaping @Sendable () -> [String] = { [] }
    ) {
        self.fileManager = fileManager
        self.homeDirectoryPath = homeDirectoryPath ?? fileManager.homeDirectoryForCurrentUser.path
        self.customProfilePaths = customProfilePaths
    }

    /// Returns one `ClaudeDesktopProfile` per existing profile directory (the
    /// two standard ones plus any configured custom dirs). Directories that do
    /// not exist are skipped silently — a machine may have only one profile, or
    /// none. Deduplicated by standardized absolute path so a custom path that
    /// repeats a standard one is not visited twice.
    public func discoverProfiles() -> [ClaudeDesktopProfile] {
        let standardPaths = Self.standardRelativePaths.map { "\(homeDirectoryPath)/\($0)" }
        let allPaths = standardPaths + customProfilePaths()

        var seen = Set<String>()
        var profiles: [ClaudeDesktopProfile] = []
        for path in allPaths {
            let standardized = (path as NSString).standardizingPath
            guard seen.insert(standardized).inserted else { continue }
            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: standardized, isDirectory: &isDirectory),
                  isDirectory.boolValue else {
                continue
            }
            profiles.append(readProfile(atDirectory: standardized))
        }
        return profiles
    }

    private func readProfile(atDirectory directoryPath: String) -> ClaudeDesktopProfile {
        let name = (directoryPath as NSString).lastPathComponent
        let configPath = "\(directoryPath)/\(Self.configFileName)"
        let encryptedTokenCache = readTokenCache(atConfigPath: configPath)
        return ClaudeDesktopProfile(
            name: name,
            directoryPath: directoryPath,
            encryptedTokenCache: encryptedTokenCache
        )
    }

    private func readTokenCache(atConfigPath configPath: String) -> String? {
        guard let data = fileManager.contents(atPath: configPath),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let value = json[Self.tokenCacheConfigKey] as? String,
              !value.isEmpty else {
            return nil
        }
        return value
    }
}
