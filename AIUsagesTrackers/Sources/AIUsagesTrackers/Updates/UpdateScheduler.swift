import Foundation

/// Periodically polls `UpdateChecker` and updates a `UpdateState`. Runs an
/// initial check shortly after start, then on a fixed interval.
public actor UpdateScheduler {
    public static let defaultInterval: Duration = .seconds(6 * 60 * 60)
    private static let initialDelay: Duration = .seconds(5)

    private let checker: UpdateChecker
    private let detector: InstallationDetector
    private let currentVersion: AppVersion
    private let interval: Duration
    private let logger: FileLogger
    private let preferencesAccessor: @Sendable @MainActor () -> any AppPreferences
    private let stateAccessor: @Sendable @MainActor () -> UpdateState
    private let onUpdateAvailable: @Sendable @MainActor (AvailableUpdate, InstallationKind) -> Void

    private var task: Task<Void, Never>?
    /// Last version the scheduler proactively notified the user about — used to
    /// avoid re-popping the alert on every poll while the version is unchanged.
    private var lastNotifiedVersion: String?

    public init(
        checker: UpdateChecker,
        detector: InstallationDetector,
        currentVersion: AppVersion,
        interval: Duration = UpdateScheduler.defaultInterval,
        preferencesAccessor: @escaping @Sendable @MainActor () -> any AppPreferences,
        stateAccessor: @escaping @Sendable @MainActor () -> UpdateState,
        onUpdateAvailable: @escaping @Sendable @MainActor (AvailableUpdate, InstallationKind) -> Void,
        logger: FileLogger = Loggers.app
    ) {
        self.checker = checker
        self.detector = detector
        self.currentVersion = currentVersion
        self.interval = interval
        self.preferencesAccessor = preferencesAccessor
        self.stateAccessor = stateAccessor
        self.onUpdateAvailable = onUpdateAvailable
        self.logger = logger
    }

    public func start() {
        guard task == nil else { return }
        let interval = self.interval
        task = Task { [self] in
            do {
                try await Task.sleep(for: Self.initialDelay)
            } catch { return }
            while !Task.isCancelled {
                await self.checkOnce()
                do {
                    try await Task.sleep(for: interval)
                } catch { break }
            }
        }
        logger.log(.info, "UpdateScheduler: started")
    }

    public func stop() {
        task?.cancel()
        task = nil
    }

    /// Manual trigger from "Check for updates now". Always runs, regardless of
    /// auto-check preference.
    public func checkNow() async {
        await checkOnce(forceUserVisible: true)
    }

    public func checkOnce(forceUserVisible: Bool = false) async {
        let prefs = await prefsSnapshot()
        if !forceUserVisible && !prefs.autoCheckEnabled {
            return
        }
        await Task { @MainActor in stateAccessor().setChecking() }.value

        do {
            let installation = await detector.detect()
            let result = try await checker.checkForUpdate(currentVersion: currentVersion)
            let now = Date()
            await Task { @MainActor in
                stateAccessor().setAvailable(result.update, latestVersion: result.latestVersion, kind: installation.kind, checkedAt: now)
            }.value
            if let update = result.update {
                let isNewToUser = (lastNotifiedVersion != update.version.rawValue)
                let isDismissed = prefs.dismissedVersions.contains(update.version.rawValue)
                if isNewToUser && !isDismissed {
                    lastNotifiedVersion = update.version.rawValue
                    let kind = installation.kind
                    await Task { @MainActor in
                        onUpdateAvailable(update, kind)
                    }.value
                }
            }
        } catch {
            let now = Date()
            let message = String(describing: error)
            logger.log(.warning, "UpdateScheduler: check failed: \(error)")
            await Task { @MainActor in stateAccessor().setError(message, at: now) }.value
        }
    }

    private struct PrefsSnapshot: Sendable {
        let autoCheckEnabled: Bool
        let dismissedVersions: Set<String>
    }

    private func prefsSnapshot() async -> PrefsSnapshot {
        await Task { @MainActor in
            let prefs = preferencesAccessor()
            return PrefsSnapshot(
                autoCheckEnabled: prefs.updatesAutoCheckEnabled,
                dismissedVersions: Set(prefs.updatesDismissedVersions)
            )
        }.value
    }
}
