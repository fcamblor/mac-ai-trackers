import Foundation

/// Strategy describing how to finalize a previously-prepared update — i.e.
/// swap the staged bundle into place (manual installs) or simply relaunch
/// (Homebrew installs, where `brew upgrade --cask` already replaced the bundle).
///
/// The actual download + extraction (manual) and `brew upgrade` invocation
/// happen earlier, in-app, so the UI can render progress. The script returned
/// here only handles the post-quit hand-off: wait for parent → swap → relaunch.
public struct UpdateFinalizationPlan: Sendable, Equatable {
    /// Path to the shell script that must be executed in a detached child
    /// process. The script handles waiting for parent exit, performing the
    /// final swap (manual only), and relaunching the app.
    public let scriptPath: String
    /// Human-readable summary.
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
    case missingStagedApp(path: String)
}

/// Builds finalization scripts that run after the app quits:
/// - Manual: move staged `.app` over the running bundle, then relaunch.
/// - Homebrew: relaunch only (brew has already swapped the bundle in-place).
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

    /// Returns the standard staging directory for downloaded / extracted bundles
    /// — exposed so the downloader and the installer agree on the location.
    public static func defaultStagingDirectory() -> URL {
        defaultScriptDirectory().appendingPathComponent("staging", isDirectory: true)
    }

    /// Build a finalization plan for the manual install path. The caller must
    /// have already extracted the new `.app` to `stagedAppPath` (see
    /// `UpdateDownloader`).
    public func buildManualFinalizationPlan(
        stagedAppPath: String,
        bundlePath: String,
        currentPID: Int32,
        update: AvailableUpdate
    ) throws -> UpdateFinalizationPlan {
        guard bundlePath.hasSuffix(".app") else {
            throw UpdateInstallerError.invalidBundlePath(path: bundlePath)
        }
        guard fileManager.fileExists(atPath: stagedAppPath) else {
            throw UpdateInstallerError.missingStagedApp(path: stagedAppPath)
        }
        try fileManager.createDirectory(at: scriptDirectory, withIntermediateDirectories: true)

        let logPath = scriptDirectory.appendingPathComponent("install.log").path
        let script = Self.manualSwapScript(
            stagedAppPath: stagedAppPath,
            bundlePath: bundlePath,
            parentPID: currentPID,
            logPath: logPath
        )
        let scriptURL = scriptDirectory
            .appendingPathComponent("finalize-manual-\(Self.safeScriptFileComponent(update.version.rawValue)).sh")
        try Self.writeScript(script, to: scriptURL, fileManager: fileManager)

        let requiresAdmin = !Self.canReplaceBundle(at: bundlePath, fileManager: fileManager)
        let summary = "Swap staged \(update.version) bundle into place and relaunch"
        logger.log(.info, "Built manual finalize plan: \(summary) → \(scriptURL.path) (admin=\(requiresAdmin))")
        return UpdateFinalizationPlan(
            scriptPath: scriptURL.path,
            summary: summary,
            requiresAdminPrivileges: requiresAdmin
        )
    }

    /// Build a finalization plan for the Homebrew path: brew has already
    /// replaced the bundle, so we only need to wait for parent exit and
    /// relaunch as the console user.
    public func buildHomebrewFinalizationPlan(
        bundlePath: String,
        currentPID: Int32,
        update: AvailableUpdate
    ) throws -> UpdateFinalizationPlan {
        try fileManager.createDirectory(at: scriptDirectory, withIntermediateDirectories: true)

        let logPath = scriptDirectory.appendingPathComponent("install.log").path
        let script = Self.relaunchOnlyScript(
            bundlePath: bundlePath,
            parentPID: currentPID,
            logPath: logPath
        )
        let scriptURL = scriptDirectory
            .appendingPathComponent("finalize-brew-\(Self.safeScriptFileComponent(update.version.rawValue)).sh")
        try Self.writeScript(script, to: scriptURL, fileManager: fileManager)

        let summary = "Relaunch \(update.version) (already installed by Homebrew)"
        logger.log(.info, "Built brew finalize plan: \(summary) → \(scriptURL.path)")
        return UpdateFinalizationPlan(
            scriptPath: scriptURL.path,
            summary: summary,
            // Brew never needs admin for relaunch.
            requiresAdminPrivileges: false
        )
    }

    private static func writeScript(_ script: String, to url: URL, fileManager: FileManager) throws {
        let data = Data(script.utf8)
        do {
            try data.write(to: url, options: .atomic)
        } catch {
            throw UpdateInstallerError.scriptWriteFailed(
                path: url.path,
                message: String(describing: error)
            )
        }
        try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
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

    private static func manualSwapScript(
        stagedAppPath: String,
        bundlePath: String,
        parentPID: Int32,
        logPath: String
    ) -> String {
        let quotedStaged = shellQuote(stagedAppPath)
        let quotedBundle = shellQuote(bundlePath)
        let quotedLog = shellQuote(logPath)
        return """
        #!/bin/bash
        set -u
        exec >> \(quotedLog) 2>&1
        echo "[$(date)] manual finalize starting (parent=\(parentPID))"
        for i in $(seq 1 60); do
            if ! kill -0 \(parentPID) 2>/dev/null; then break; fi
            sleep 0.5
        done
        if [ ! -e \(quotedStaged) ]; then
            echo "[$(date)] staged bundle missing at \(stagedAppPath)"
            exit 1
        fi
        BACKUP=\(quotedBundle).old-$(date +%s)
        if [ -e \(quotedBundle) ]; then
            if ! /bin/mv \(quotedBundle) "$BACKUP"; then
                echo "[$(date)] backup failed"; exit 2
            fi
        fi
        if ! /bin/mv \(quotedStaged) \(quotedBundle); then
            echo "[$(date)] swap failed; restoring backup"
            /bin/mv "$BACKUP" \(quotedBundle) 2>/dev/null
            exit 3
        fi
        rm -rf "$BACKUP"
        /usr/bin/xattr -dr com.apple.quarantine \(quotedBundle) 2>/dev/null || true
        echo "[$(date)] relaunching"
        \(relaunchSnippet(quotedBundle: quotedBundle))
        """
    }

    private static func relaunchOnlyScript(
        bundlePath: String,
        parentPID: Int32,
        logPath: String
    ) -> String {
        let quotedBundle = shellQuote(bundlePath)
        let quotedLog = shellQuote(logPath)
        return """
        #!/bin/bash
        set -u
        exec >> \(quotedLog) 2>&1
        echo "[$(date)] brew finalize relaunch (parent=\(parentPID))"
        for i in $(seq 1 60); do
            if ! kill -0 \(parentPID) 2>/dev/null; then break; fi
            sleep 0.5
        done
        \(relaunchSnippet(quotedBundle: quotedBundle))
        """
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

    private static func shellQuote(_ value: String) -> String {
        "'\(value.replacingOccurrences(of: "'", with: "'\\''"))'"
    }

    private static func safeScriptFileComponent(_ value: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "._-"))
        let scalars = value.unicodeScalars.map { allowed.contains($0) ? Character($0) : "_" }
        let sanitized = String(scalars)
        return sanitized.isEmpty ? "update" : sanitized
    }
}
