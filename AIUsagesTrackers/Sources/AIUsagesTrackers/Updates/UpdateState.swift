import Foundation
import Observation

/// Observable holder used by the menu bar popover to display a banner when a
/// newer release is available, and to reflect "checking" / multi-step install
/// progress (download / verify / extract / homebrew run / ready-to-restart).
@Observable
@MainActor
public final class UpdateState {
    public enum Phase: Sendable, Equatable {
        case idle
        case checking
        /// Right after the user clicked "Install": building plan, resolving brew, etc.
        case preparing
        /// Manual install: zip download in progress.
        case downloading(receivedBytes: Int64, totalBytes: Int64?)
        /// Manual install: SHA256 check.
        case verifying
        /// Manual install: ditto unzip.
        case extracting
        /// Homebrew install: `brew upgrade --cask` running, with last log line
        /// from stdout/stderr (truncated) for user feedback.
        case runningHomebrew(lastLine: String?)
        /// All work is done; the user can click "Restart" whenever they're ready.
        /// For manual installs the new bundle is staged at `stagedAppPath` and
        /// will be swapped in by the finalize script. For Homebrew the swap is
        /// already complete — restart simply relaunches the bundle.
        case readyToRestart
        /// User clicked "Restart": finalize script launched, app is about to quit.
        case restarting
        /// Anything failed during install. Banner shows the message with a Retry button.
        case failed(message: String)
    }

    public private(set) var phase: Phase = .idle
    public private(set) var availableUpdate: AvailableUpdate?
    public private(set) var latestKnownVersion: AppVersion?
    public private(set) var lastCheckedAt: Date?
    public private(set) var lastError: String?
    public private(set) var installationKind: InstallationKind?
    /// Set during the manual install flow once extraction succeeds — the path
    /// to the staged `.app` bundle ready to swap into place.
    public private(set) var stagedAppPath: String?
    /// Versions the user explicitly chose to skip. Persisted in preferences so
    /// the banner stays dismissed across launches.
    public var dismissedVersions: Set<String>

    public init(dismissedVersions: Set<String> = []) {
        self.dismissedVersions = dismissedVersions
    }

    public func setChecking() {
        phase = .checking
        lastError = nil
    }

    public func setIdle(checkedAt: Date) {
        phase = .idle
        lastCheckedAt = checkedAt
    }

    public func setAvailable(_ update: AvailableUpdate?, latestVersion: AppVersion?, kind: InstallationKind?, checkedAt: Date) {
        availableUpdate = update
        latestKnownVersion = latestVersion
        installationKind = kind
        lastCheckedAt = checkedAt
        phase = .idle
    }

    public func setError(_ message: String, at: Date) {
        phase = .idle
        lastError = message
        lastCheckedAt = at
    }

    public func setPreparing() {
        phase = .preparing
        lastError = nil
        stagedAppPath = nil
    }

    public func setDownloading(received: Int64, total: Int64?) {
        phase = .downloading(receivedBytes: received, totalBytes: total)
    }

    public func setVerifying() { phase = .verifying }
    public func setExtracting() { phase = .extracting }

    public func setRunningHomebrew(lastLine: String?) {
        phase = .runningHomebrew(lastLine: lastLine)
    }

    public func setReadyToRestart(stagedAppPath: String?) {
        self.stagedAppPath = stagedAppPath
        phase = .readyToRestart
    }

    public func setRestarting() { phase = .restarting }

    public func setFailed(_ message: String) {
        phase = .failed(message: message)
    }

    public func dismissCurrent() {
        if let version = availableUpdate?.version.rawValue {
            dismissedVersions.insert(version)
        }
        availableUpdate = nil
        phase = .idle
        stagedAppPath = nil
    }

    /// Returns the available update only when the user hasn't dismissed it.
    public var pendingUpdate: AvailableUpdate? {
        guard let update = availableUpdate else { return nil }
        if dismissedVersions.contains(update.version.rawValue) { return nil }
        return update
    }

    /// True while the install pipeline is in flight (download / verify / extract /
    /// brew / restarting). Used by the UI to disable cancel/skip controls.
    public var isInstallInProgress: Bool {
        switch phase {
        case .preparing, .downloading, .verifying, .extracting, .runningHomebrew, .restarting:
            return true
        case .idle, .checking, .readyToRestart, .failed:
            return false
        }
    }

    public var isReadyToRestart: Bool {
        if case .readyToRestart = phase { return true }
        return false
    }
}
