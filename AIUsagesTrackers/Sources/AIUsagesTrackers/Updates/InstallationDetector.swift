import Foundation

public enum InstallationKind: Sendable, Equatable {
    /// Installed via Homebrew cask `ai-usages-tracker`.
    case homebrewCask
    /// Bundle lives outside any known package manager prefix — the user copied
    /// the .app manually (e.g. dragged into /Applications, or running ad-hoc).
    case manual
}

public struct InstallationInfo: Sendable, Equatable {
    public let kind: InstallationKind
    public let bundlePath: String

    public init(kind: InstallationKind, bundlePath: String) {
        self.kind = kind
        self.bundlePath = bundlePath
    }
}

/// Detects how the running app bundle was installed, so the installer can pick
/// the right upgrade path (Homebrew cask vs. direct zip replacement).
public actor InstallationDetector {
    private let bundlePath: String
    private let process: ProcessRunning
    private let fileManager: FileManager
    private let homebrewBinaryPaths: [String]
    private let pathEnvironment: String?

    public static let homebrewCaskName = "ai-usages-tracker"

    public init(
        bundlePath: String,
        process: ProcessRunning = FoundationProcessRunner(),
        fileManager: FileManager = .default,
        homebrewBinaryPaths: [String] = ["/opt/homebrew/bin/brew", "/usr/local/bin/brew"],
        pathEnvironment: String? = ProcessInfo.processInfo.environment["PATH"]
    ) {
        self.bundlePath = bundlePath
        self.process = process
        self.fileManager = fileManager
        self.homebrewBinaryPaths = homebrewBinaryPaths
        self.pathEnvironment = pathEnvironment
    }

    public func detect() async -> InstallationInfo {
        guard let brewPath = firstExistingBrewPath() else {
            return InstallationInfo(kind: .manual, bundlePath: bundlePath)
        }
        // `brew --caskroom` returns the directory containing per-cask folders.
        // The `app` cask stanza copies the .app into /Applications rather than
        // symlinking it, so the running bundle path can't confirm provenance.
        // Instead, the existence of `<caskroom>/<name>` as a directory is the
        // canonical signal that the cask is installed on this machine.
        let caskroom: String
        do {
            let result = try await process.run(
                executablePath: brewPath,
                arguments: ["--caskroom"],
                timeoutSeconds: 5
            )
            guard result.terminationStatus == 0, !result.timedOut else {
                return InstallationInfo(kind: .manual, bundlePath: bundlePath)
            }
            caskroom = String(decoding: result.stdout, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
        } catch {
            return InstallationInfo(kind: .manual, bundlePath: bundlePath)
        }

        guard !caskroom.isEmpty else {
            return InstallationInfo(kind: .manual, bundlePath: bundlePath)
        }

        let caskDir = caskroom.hasSuffix("/") ? "\(caskroom)\(Self.homebrewCaskName)" : "\(caskroom)/\(Self.homebrewCaskName)"
        var isDirectory: ObjCBool = false
        if fileManager.fileExists(atPath: caskDir, isDirectory: &isDirectory), isDirectory.boolValue {
            return InstallationInfo(kind: .homebrewCask, bundlePath: bundlePath)
        }
        return InstallationInfo(kind: .manual, bundlePath: bundlePath)
    }

    /// Exposed for the installer — returns the path of an existing brew binary
    /// or nil if Homebrew is not installed at the expected locations.
    public func brewExecutablePath() -> String? {
        firstExistingBrewPath()
    }

    private func firstExistingBrewPath() -> String? {
        let pathBrewCandidates = (pathEnvironment ?? "")
            .split(separator: ":")
            .map { String($0) }
            .filter { !$0.isEmpty }
            .map { URL(fileURLWithPath: $0).appendingPathComponent("brew").path }
        return (homebrewBinaryPaths + pathBrewCandidates).first { fileManager.fileExists(atPath: $0) }
    }

}
