import Foundation
import Observation

/// Observable holder used by the menu bar popover to display a banner when a
/// newer release is available, and to reflect "checking" / "installing" state.
@Observable
@MainActor
public final class UpdateState {
    public enum Phase: Sendable, Equatable {
        case idle
        case checking
        case installing
    }

    public private(set) var phase: Phase = .idle
    public private(set) var availableUpdate: AvailableUpdate?
    public private(set) var lastCheckedAt: Date?
    public private(set) var lastError: String?
    public private(set) var installationKind: InstallationKind?
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

    public func setAvailable(_ update: AvailableUpdate?, kind: InstallationKind?, checkedAt: Date) {
        availableUpdate = update
        installationKind = kind
        lastCheckedAt = checkedAt
        phase = .idle
    }

    public func setError(_ message: String, at: Date) {
        phase = .idle
        lastError = message
        lastCheckedAt = at
    }

    public func setInstalling() {
        phase = .installing
    }

    public func dismissCurrent() {
        if let version = availableUpdate?.version.rawValue {
            dismissedVersions.insert(version)
        }
        availableUpdate = nil
    }

    /// Returns the available update only when the user hasn't dismissed it.
    public var pendingUpdate: AvailableUpdate? {
        guard let update = availableUpdate else { return nil }
        if dismissedVersions.contains(update.version.rawValue) { return nil }
        return update
    }
}
