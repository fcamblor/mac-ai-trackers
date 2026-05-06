import Foundation

/// Strategy describing how to install a given `AvailableUpdate` for a given
/// `InstallationInfo`. The actual launch is deferred to the caller so the app
/// can run the script *after* releasing its own resources.
public struct UpdateInstallationPlan: Sendable, Equatable {
    /// Path to the shell script that must be executed in a detached child
    /// process. The script handles waiting for parent exit, performing the
    /// upgrade, and relaunching the app.
    public let scriptPath: String
    /// Human-readable summary of what the script will do.
    public let summary: String
    /// True when the bundle (or its parent directory) is not writable by the
    /// current user — the caller must launch the script with elevated
    /// privileges (e.g. via `osascript ... with administrator privileges`).
    public let requiresAdminPrivileges: Bool

    public init(scriptPath: String, summary: String, requiresAdminPrivileges: Bool) {
        self.scriptPath = scriptPath
        self.summary = summary
        self.requiresAdminPrivileges = requiresAdminPrivileges
    }
}

public enum UpdateInstallerError: Error, Equatable {
    case scriptWriteFailed(path: String, message: String)
    case invalidBundlePath(path: String)
}

/// Builds an installation plan tailored to the detected installation kind.
/// - Homebrew: emits a shell script that waits for the app to exit, runs
///   `brew upgrade --cask <name>`, then relaunches.
/// - Manual: emits a shell script that downloads the release zip, verifies
///   its sha256, atomically replaces the bundle, then relaunches.
public actor UpdateInstaller {
    private let fileManager: FileManager
    private let scriptDirectory: URL
    private let logger: FileLogger

    public init(
        fileManager: FileManager = .default,
        scriptDirectory: URL? = nil,
        logger: FileLogger = Loggers.app
    ) {
        self.fileManager = fileManager
        self.scriptDirectory = scriptDirectory ?? Self.defaultScriptDirectory()
        self.logger = logger
    }

    private static func defaultScriptDirectory() -> URL {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return home.appendingPathComponent(".cache/ai-usages-tracker/updates", isDirectory: true)
    }

    public func buildPlan(
        for update: AvailableUpdate,
        installation: InstallationInfo,
        brewExecutablePath: String?,
        currentPID: Int32
    ) throws -> UpdateInstallationPlan {
        try fileManager.createDirectory(at: scriptDirectory, withIntermediateDirectories: true)

        let script: String
        let summary: String
        switch installation.kind {
        case .homebrewCask:
            // brew is required; without it we degrade to manual installation.
            if let brew = brewExecutablePath {
                script = Self.brewUpgradeScript(
                    brewPath: brew,
                    caskName: InstallationDetector.homebrewCaskName,
                    bundlePath: installation.bundlePath,
                    parentPID: currentPID,
                    logPath: scriptDirectory.appendingPathComponent("install.log").path
                )
                summary = "Upgrade via Homebrew cask \(InstallationDetector.homebrewCaskName)"
            } else {
                script = Self.manualUpgradeScript(
                    update: update,
                    bundlePath: installation.bundlePath,
                    workDir: scriptDirectory.path,
                    parentPID: currentPID,
                    logPath: scriptDirectory.appendingPathComponent("install.log").path
                )
                summary = "Download \(update.version) and replace app bundle"
            }
        case .manual:
            guard installation.bundlePath.hasSuffix(".app") else {
                throw UpdateInstallerError.invalidBundlePath(path: installation.bundlePath)
            }
            script = Self.manualUpgradeScript(
                update: update,
                bundlePath: installation.bundlePath,
                workDir: scriptDirectory.path,
                parentPID: currentPID,
                logPath: scriptDirectory.appendingPathComponent("install.log").path
            )
            summary = "Download \(update.version) and replace app bundle"
        }

        let scriptURL = scriptDirectory.appendingPathComponent("install-\(Self.safeScriptFileComponent(update.version.rawValue)).sh")
        let data = Data(script.utf8)
        do {
            try data.write(to: scriptURL, options: .atomic)
        } catch {
            throw UpdateInstallerError.scriptWriteFailed(
                path: scriptURL.path,
                message: String(describing: error)
            )
        }
        try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptURL.path)

        // Brew handles its own ownership semantics, so we never need admin auth
        // for the cask path; only the manual replacement can hit a root-owned
        // bundle (e.g. when installed via a privileged .pkg).
        let requiresAdmin: Bool
        switch installation.kind {
        case .homebrewCask where brewExecutablePath != nil:
            requiresAdmin = false
        case .homebrewCask, .manual:
            requiresAdmin = !Self.canReplaceBundle(at: installation.bundlePath, fileManager: fileManager)
        }

        logger.log(.info, "Built update plan: \(summary) → \(scriptURL.path) (admin=\(requiresAdmin))")
        return UpdateInstallationPlan(
            scriptPath: scriptURL.path,
            summary: summary,
            requiresAdminPrivileges: requiresAdmin
        )
    }

    /// True when the running user can move/replace the bundle without admin
    /// elevation: both the bundle itself and its parent directory must be
    /// writable. Missing bundle paths fall back to false (treat as "needs
    /// admin" rather than silently succeed-then-fail at runtime).
    static func canReplaceBundle(at bundlePath: String, fileManager: FileManager) -> Bool {
        let parent = (bundlePath as NSString).deletingLastPathComponent
        let parentWritable = fileManager.isWritableFile(atPath: parent)
        if !fileManager.fileExists(atPath: bundlePath) {
            return parentWritable
        }
        return parentWritable && fileManager.isWritableFile(atPath: bundlePath)
    }

    // MARK: - Script templates

    private static func brewUpgradeScript(
        brewPath: String,
        caskName: String,
        bundlePath: String,
        parentPID: Int32,
        logPath: String
    ) -> String {
        // Wait for parent to exit (max 30 s) so brew can swap the bundle
        // without "in use" errors, then reinstall and relaunch.
        let quotedBrew = shellQuote(brewPath)
        let quotedCask = shellQuote(caskName)
        let quotedLog = shellQuote(logPath)
        let quotedBundle = shellQuote(bundlePath)
        return """
        #!/bin/bash
        set -u
        exec >> \(quotedLog) 2>&1
        echo "[$(date)] update via brew starting (parent=\(parentPID))"
        for i in $(seq 1 60); do
            if ! kill -0 \(parentPID) 2>/dev/null; then break; fi
            sleep 0.5
        done
        \(quotedBrew) update >/dev/null || true
        if ! \(quotedBrew) upgrade --cask \(quotedCask); then
            echo "[$(date)] brew upgrade failed"
            exit 1
        fi
        echo "[$(date)] relaunching"
        \(Self.relaunchSnippet(quotedBundle: quotedBundle))
        """
    }

    private static func shellQuote(_ value: String) -> String {
        "'\(value.replacingOccurrences(of: "'", with: "'\\''"))'"
    }

    private static func safeScriptFileComponent(_ value: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "._-"))
        let scalars = value.unicodeScalars.map { allowed.contains($0) ? Character($0) : "_" }
        let sanitized = String(scalars)
        return sanitized.isEmpty ? "update" : sanitized
    }

    /// Relaunch as the console user even when the script runs as root — when
    /// the script is invoked through `osascript ... with administrator
    /// privileges`, `/usr/bin/open` would otherwise launch the app as root and
    /// poison subsequent file ownership.
    private static func relaunchSnippet(quotedBundle: String) -> String {
        return """
        if [ "$(id -u)" = "0" ]; then
            USER_UID=$(/usr/bin/stat -f "%u" /dev/console)
            /bin/launchctl asuser "$USER_UID" /usr/bin/open \(quotedBundle)
        else
            /usr/bin/open \(quotedBundle)
        fi
        """
    }

    private static func manualUpgradeScript(
        update: AvailableUpdate,
        bundlePath: String,
        workDir: String,
        parentPID: Int32,
        logPath: String
    ) -> String {
        let quotedBundle = shellQuote(bundlePath)
        let quotedLog = shellQuote(logPath)
        let quotedWorkDir = shellQuote("\(workDir)/staging-\(update.version.rawValue)")
        let quotedZipURL = shellQuote(update.downloadURL.absoluteString)
        let quotedShaURL = shellQuote(update.sha256URL?.absoluteString ?? "")
        return """
        #!/bin/bash
        set -u
        exec >> \(quotedLog) 2>&1
        WORK=\(quotedWorkDir)
        rm -rf "$WORK"
        mkdir -p "$WORK"
        cd "$WORK"
        echo "[$(date)] manual update starting (parent=\(parentPID))"
        for i in $(seq 1 60); do
            if ! kill -0 \(parentPID) 2>/dev/null; then break; fi
            sleep 0.5
        done
        if ! /usr/bin/curl --fail --silent --show-error --location -o release.zip \(quotedZipURL); then
            echo "[$(date)] download failed"; exit 1
        fi
        SHA_URL=\(quotedShaURL)
        if [ -n "$SHA_URL" ]; then
            if ! /usr/bin/curl --fail --silent --show-error --location -o release.zip.sha256 "$SHA_URL"; then
                echo "[$(date)] sha256 download failed"; exit 2
            fi
            EXPECTED=$(awk '{print $1}' release.zip.sha256)
            ACTUAL=$(/usr/bin/shasum -a 256 release.zip | awk '{print $1}')
            if [ "$EXPECTED" != "$ACTUAL" ]; then
                echo "[$(date)] sha256 mismatch: expected=$EXPECTED actual=$ACTUAL"; exit 2
            fi
        fi
        if ! /usr/bin/ditto -x -k release.zip extracted; then
            echo "[$(date)] unzip failed"; exit 3
        fi
        NEW_APP=$(find extracted -maxdepth 2 -name "*.app" -type d | head -1)
        if [ -z "$NEW_APP" ]; then
            echo "[$(date)] no .app inside zip"; exit 4
        fi
        BACKUP=\(quotedBundle).old-$(date +%s)
        if [ -e \(quotedBundle) ]; then
            if ! /bin/mv \(quotedBundle) "$BACKUP"; then
                echo "[$(date)] backup failed"; exit 5
            fi
        fi
        if ! /bin/mv "$NEW_APP" \(quotedBundle); then
            echo "[$(date)] move new bundle failed; restoring backup"
            /bin/mv "$BACKUP" \(quotedBundle) 2>/dev/null
            exit 6
        fi
        rm -rf "$BACKUP"
        echo "[$(date)] relaunching"
        /usr/bin/xattr -dr com.apple.quarantine \(quotedBundle) 2>/dev/null || true
        \(Self.relaunchSnippet(quotedBundle: quotedBundle))
        """
    }
}
