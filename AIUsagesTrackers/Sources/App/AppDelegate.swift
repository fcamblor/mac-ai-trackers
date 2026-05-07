import AppKit
import SwiftUI
import AIUsagesTrackersLib
import AppIconKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var poller: UsagePoller?
    private var snapshotScheduler: SnapshotScheduler?
    private var pidGuard: AppPidGuard?
    private var usageStore: UsageStore?
    private var refreshState: RefreshState?
    private var statusItem: NSStatusItem?
    private var popover: NSPopover?
    private var appearanceObserver: NSKeyValueObservation?
    private var settingsWindowObserver: NSObjectProtocol?
    private var updateScheduler: UpdateScheduler?
    private var updateInstaller: UpdateInstaller?
    private var installationDetector: InstallationDetector?
    private var updateDownloader: UpdateDownloader?
    private var brewUpgradeRunner: BrewUpgradeRunner?
    /// Holds the in-flight install Task so a second click on "Install" doesn't
    /// kick off a parallel pipeline.
    private var activeInstallTask: Task<Void, Never>?
    /// Captured at the start of an install so the finalize step knows whether
    /// we ran the Homebrew or manual path.
    private var activeInstallKind: InstallationKind?
    private var activeInstallBundlePath: String?

    /// Shared preferences store — exposed as static so the SwiftUI Settings scene
    /// (constructed before applicationDidFinishLaunching) can access it.
    static let sharedPreferences: UserDefaultsAppPreferences = UserDefaultsAppPreferences()

    /// Shared usage store — populated in applicationDidFinishLaunching. The Settings
    /// scene is instantiated before the store exists, so it must read through this
    /// mutable holder. Nil until the first launch callback has run.
    static var sharedStore: UsageStore?

    /// Shared observable update state — read by the popover banner and Settings.
    static let sharedUpdateState: UpdateState = UpdateState()

    /// Pointer to the running update scheduler so Settings can trigger a manual check.
    static var sharedUpdateScheduler: UpdateScheduler?

    /// Closure exposed to Settings so the user can launch installation of the
    /// current pending update without going through the popover banner.
    static var sharedTriggerUpdateInstall: (() -> Void)?

    /// Closure called when the user clicks "Restart now" once the update has
    /// been downloaded/extracted (manual) or installed by Homebrew.
    static var sharedTriggerRestart: (() -> Void)?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApplication.shared.setActivationPolicy(.accessory)

        // No .app bundle ships with this SwiftPM executable, so AppKit has no
        // static icon slot — set the Dock / Cmd+Tab icon programmatically.
        if let icon = AppIconRenderer.makeImage(pixelSize: 1024) {
            NSApplication.shared.applicationIconImage = icon
        }

        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let guard_ = AppPidGuard(cacheDir: "\(home)/.cache/ai-usages-tracker")
        do {
            try guard_.acquire()
        } catch AppPidGuardError.alreadyRunning(let pid, _) {
            let alert = NSAlert()
            alert.messageText = "AI Usages Tracker is already running"
            alert.informativeText = "Another instance is active (PID \(pid)). Use the menu bar icon to quit it before launching a new one."
            alert.runModal()
            NSApplication.shared.terminate(nil)
            return
        } catch {
            let alert = NSAlert()
            alert.messageText = "Failed to start AI Usages Tracker"
            alert.informativeText = error.localizedDescription
            alert.runModal()
            NSApplication.shared.terminate(nil)
            return
        }
        pidGuard = guard_

        Loggers.setPreferences(Self.sharedPreferences)

        MenuBarSegmentsSeeder.seedIfNeeded(preferences: Self.sharedPreferences)
        ChartConfigurationsSeeder.seedIfNeeded(preferences: Self.sharedPreferences)

        // Reconcile launch-at-login preference with system state — the user may
        // have disabled the entry in System Settings > Login Items directly.
        let launchService = LaunchAtLoginService.shared
        if Self.sharedPreferences.launchAtLogin != launchService.isEnabled {
            Self.sharedPreferences.launchAtLogin = launchService.isEnabled
        }

        let fileManager = UsagesFileManager.shared
        let refreshState = RefreshState()
        let claudeConnector = ClaudeCodeConnector()
        let claudeStatus = ClaudeStatusConnector()
        let codexConnector = CodexConnector()
        let codexStatus = CodexStatusConnector()
        let poller = UsagePoller(
            connectors: [claudeConnector, codexConnector],
            statusConnectors: [claudeStatus, codexStatus],
            fileManager: fileManager,
            refreshState: refreshState,
            preferences: Self.sharedPreferences
        )
        let claudeMonitor = ClaudeActiveAccountMonitor(
            fileManager: fileManager,
            onActiveAccountChanged: { [weak poller] _ in
                await poller?.pollOnce(force: true)
            }
        )
        let codexMonitor = CodexActiveAccountMonitor(
            onActiveAccountChanged: { [weak codexConnector, weak poller] _ in
                await codexConnector?.invalidateEmailCache()
                await poller?.pollOnce(force: true)
            }
        )
        VendorRegistry.resetForTesting()
        ClaudeCodePlugin.register(connector: claudeConnector, status: claudeStatus, monitor: claudeMonitor)
        CodexPlugin.register(connector: codexConnector, status: codexStatus, monitor: codexMonitor)
        let snapshotRecorder = SnapshotRecorder()
        let historyReader = UsageHistoryReader(rootPath: snapshotRecorder.rootPath)
        let snapshotScheduler = SnapshotScheduler(
            fileManager: fileManager,
            recorder: snapshotRecorder
        )
        self.poller = poller
        self.snapshotScheduler = snapshotScheduler
        self.refreshState = refreshState

        let usagesPath = fileManager.filePath
        let fileWatcher = UsagesFileWatcher(path: usagesPath)
        let store = UsageStore(fileWatcher: fileWatcher, preferences: Self.sharedPreferences)
        self.usageStore = store
        Self.sharedStore = store

        Self.sharedUpdateState.dismissedVersions = Set(Self.sharedPreferences.updatesDismissedVersions)

        setupStatusItem(store: store, refreshState: refreshState, historyReader: historyReader)
        trackStoreChanges(store: store)
        setupUpdateScheduler()

        Task {
            await StartupMigrationRunner(fileManager: fileManager).run()
            store.start()
            await poller.start()
            await snapshotScheduler.start()
            for bundle in VendorRegistry.bundles {
                await bundle.activeAccountMonitor?.start()
            }
            if let scheduler = self.updateScheduler {
                await scheduler.start()
            }
        }
    }

    private func setupUpdateScheduler() {
        // In a development build (swift run) there's no Info.plist version, so
        // we fall back to 0.0.0 — every release will then be reported as newer,
        // but the existing "Skip this version" flow ensures the alert isn't
        // re-shown until a different version ships.
        let effectiveVersion = Self.currentAppVersion() ?? AppVersion(string: "0.0.0")!
        let bundlePath = Bundle.main.bundleURL.path
        let detector = InstallationDetector(bundlePath: bundlePath)
        self.installationDetector = detector
        self.updateInstaller = UpdateInstaller()
        self.updateDownloader = UpdateDownloader()
        self.brewUpgradeRunner = BrewUpgradeRunner()
        let scheduler = UpdateScheduler(
            checker: UpdateChecker(),
            detector: detector,
            currentVersion: effectiveVersion,
            preferencesAccessor: { Self.sharedPreferences },
            stateAccessor: { Self.sharedUpdateState },
            onUpdateAvailable: { [weak self] update, kind in
                self?.presentUpdateAlert(update: update, kind: kind)
            }
        )
        self.updateScheduler = scheduler
        Self.sharedUpdateScheduler = scheduler
        Self.sharedTriggerUpdateInstall = { [weak self] in
            self?.triggerUpdateInstall()
        }
        Self.sharedTriggerRestart = { [weak self] in
            self?.triggerRestart()
        }
    }

    static func currentAppVersion() -> AppVersion? {
        guard let raw = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String else {
            return nil
        }
        return AppVersion(string: raw)
    }

    /// Human-readable label for the running app version, falling back to a
    /// "development build" marker when launched via `swift run` (no Info.plist).
    static func currentAppVersionLabel() -> String {
        currentAppVersion()?.rawValue ?? "development build"
    }

    func applicationWillTerminate(_ notification: Notification) {
        quit()
    }

    // MARK: - Status item

    private func setupStatusItem(
        store: UsageStore,
        refreshState: RefreshState,
        historyReader: UsageHistoryReader
    ) {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem = item

        let popover = NSPopover()
        popover.behavior = .transient
        let hosting = NSHostingController(
            rootView: UsageDetailsView(
                store: store,
                refreshState: refreshState,
                historyReader: historyReader,
                updateState: Self.sharedUpdateState,
                onRefresh: { [weak self] in
                    await self?.poller?.pollOnce(now: Date(), force: true)
                },
                onOpenSettings: { [weak self] in
                    self?.openSettings()
                },
                onQuit: { [weak self] in
                    self?.quit()
                },
                onInstallUpdate: { [weak self] in
                    self?.triggerUpdateInstall()
                },
                onRestartUpdate: { [weak self] in
                    self?.triggerRestart()
                },
                onSkipUpdate: { [weak self] in
                    self?.skipCurrentUpdate()
                },
                onLaterUpdate: { [weak self] in
                    self?.laterUpdate()
                }
            )
        )
        // Let SwiftUI's intrinsic size drive the popover so it grows with content
        // up to the screen-ratio cap enforced inside UsageDetailsView.
        hosting.sizingOptions = [.preferredContentSize]
        popover.contentViewController = hosting
        self.popover = popover

        if let button = item.button {
            button.target = self
            button.action = #selector(togglePopover(_:))
            // The menu bar appearance can change (wallpaper-driven tinting) without
            // the app's effectiveAppearance changing, so we observe the button itself.
            appearanceObserver = button.observe(\.effectiveAppearance, options: [.new]) { [weak self] _, _ in
                Task { @MainActor in self?.refreshStatusItemImage() }
            }
        }

        refreshStatusItemImage()
    }

    private func refreshStatusItemImage() {
        guard let store = usageStore, let button = statusItem?.button else { return }
        let isDark = button.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let isUnconfigured = Self.sharedPreferences.menuBarSegments.isEmpty
        let warningPrefix = outageWarningPrefix(store: store)
        let image = MenuBarLabelRenderer.render(
            segments: store.menuBarSegments,
            separator: Self.sharedPreferences.menuBarSeparator,
            fallbackText: store.menuBarText,
            isDarkMenuBar: isDark,
            isUnconfigured: isUnconfigured,
            outageWarningPrefix: warningPrefix
        )
        button.image = image
    }

    /// Returns the configured warning text when outage hinting is enabled and at
    /// least one vendor currently has an active outage; nil otherwise.
    private func outageWarningPrefix(store: UsageStore) -> String? {
        let prefs = Self.sharedPreferences
        guard prefs.menuBarOutageWarningEnabled else { return nil }
        let text = prefs.menuBarOutageWarningText
        guard !text.isEmpty else { return nil }
        guard store.outagesByVendor.values.contains(where: { !$0.isEmpty }) else { return nil }
        return text
    }

    @objc private func togglePopover(_ sender: Any?) {
        guard let popover, let button = statusItem?.button else { return }
        if popover.isShown {
            popover.performClose(sender)
        } else {
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
        }
    }

    // MARK: - Observation

    /// Re-arms `withObservationTracking` after every change so the status item
    /// keeps mirroring the store. Tracking fires exactly once per registration.
    private func trackStoreChanges(store: UsageStore) {
        let prefs = Self.sharedPreferences
        withObservationTracking {
            _ = store.menuBarSegments
            _ = store.menuBarText
            _ = store.outagesByVendor
            _ = prefs.menuBarOutageWarningEnabled
            _ = prefs.menuBarOutageWarningText
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self, let store = self.usageStore else { return }
                self.refreshStatusItemImage()
                self.trackStoreChanges(store: store)
            }
        }
    }

    // MARK: - Settings

    private func openSettings() {
        popover?.performClose(nil)
        // .accessory apps have no dock presence; showSettingsWindow: silently fails
        // unless we temporarily switch to .regular so AppKit can make the window key.
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)

        // SwiftUI creates the Settings window lazily on first showSettingsWindow: —
        // if it already exists, reuse it directly to avoid responder-chain races
        // that occur during the popover-dismissal + activation-policy transition.
        if let settingsWindow = Self.findSettingsWindow() {
            settingsWindow.makeKeyAndOrderFront(nil)
        } else {
            // First-time path: AppKit needs a runloop tick after the .accessory →
            // .regular transition to install the standard App menu (which is where
            // SwiftUI wires the Settings… action). sendAction with a nil target
            // relies on that wiring, so we trigger the menu item directly once
            // AppKit has had a chance to build it.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                Self.triggerSettingsMenuItem()
                if let settingsWindow = Self.findSettingsWindow() {
                    settingsWindow.makeKeyAndOrderFront(nil)
                }
            }
        }

        // Restore .accessory policy once the settings window is closed.
        if settingsWindowObserver == nil {
            // Use selector-based observer so the callback runs on @MainActor naturally,
            // avoiding Sendable-crossing issues with block-based addObserver(queue:).
            settingsWindowObserver = self
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(handleSettingsWindowWillClose(_:)),
                name: NSWindow.willCloseNotification,
                object: nil
            )
        }
    }

    @objc private func handleSettingsWindowWillClose(_ notification: Notification) {
        // Only react to the Settings window closing — popovers and other
        // transient windows also emit willClose.
        guard let closingWindow = notification.object as? NSWindow else { return }
        let windowIdentifier = closingWindow.identifier?.rawValue ?? ""
        guard windowIdentifier.contains("Settings") || windowIdentifier.contains("Preferences") else { return }
        // willClose fires while the window is still visible and before
        // AppKit tears it down; defer to the next runloop tick so the
        // activation-policy change isn't overridden by pending AppKit work.
        DispatchQueue.main.async { [weak self] in
            NSApp.setActivationPolicy(.accessory)
            // Accessory transition doesn't always remove the app from the
            // Cmd+Tab / app-switcher list until another app is activated.
            if let frontmost = NSWorkspace.shared.runningApplications.first(where: {
                $0.isActive && $0.processIdentifier != ProcessInfo.processInfo.processIdentifier
            }) {
                frontmost.activate()
            } else {
                NSApp.hide(nil)
            }
            guard let self else { return }
            NotificationCenter.default.removeObserver(self, name: NSWindow.willCloseNotification, object: nil)
            self.settingsWindowObserver = nil
        }
    }

    /// SwiftUI tags its Settings window with an identifier containing "Settings"
    /// (or "Preferences" on older SDKs). Match on the stable identifier rather
    /// than localized titles.
    private static func findSettingsWindow() -> NSWindow? {
        NSApp.windows.first { window in
            let identifier = window.identifier?.rawValue ?? ""
            return identifier.contains("Settings") || identifier.contains("Preferences")
        }
    }

    /// Walk the main menu looking for the App menu's Settings… (or Preferences…)
    /// item and invoke it. Going through the menu guarantees the action is
    /// routed to whichever responder SwiftUI wired up, instead of relying on
    /// `sendAction(_:to:from:)` to resolve a nil target in the responder chain
    /// — which is unreliable right after an activation-policy switch.
    private static func triggerSettingsMenuItem() {
        guard let mainMenu = NSApp.mainMenu else { return }
        for topItem in mainMenu.items {
            guard let submenu = topItem.submenu else { continue }
            for (index, item) in submenu.items.enumerated() {
                let title = item.title
                if title.hasPrefix("Settings") || title.hasPrefix("Preferences") {
                    submenu.performActionForItem(at: index)
                    return
                }
            }
        }
    }

    // MARK: - Updates

    private func presentUpdateAlert(update: AvailableUpdate, kind: InstallationKind) {
        let alert = NSAlert()
        alert.icon = NSApplication.shared.applicationIconImage
        alert.messageText = "Update available"
        alert.informativeText = "Version \(update.version.rawValue) of AI Usages Tracker is available. Install it now?"
        alert.alertStyle = .informational
        let installLabel = kind == .homebrewCask ? "Update via Homebrew" : "Install"
        alert.addButton(withTitle: installLabel)
        alert.addButton(withTitle: "Later")
        alert.addButton(withTitle: "Skip this version")
        // .accessory apps don't get focus by default; activate so the modal alert
        // surfaces above other windows when the user is mid-task.
        let previousPolicy = NSApp.activationPolicy()
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        defer { NSApp.setActivationPolicy(previousPolicy) }

        switch alert.runModal() {
        case .alertFirstButtonReturn:
            triggerUpdateInstall()
        case .alertSecondButtonReturn:
            break
        case .alertThirdButtonReturn:
            skipCurrentUpdate()
        default:
            break
        }
    }

    /// Kicks off the in-app preparation pipeline (download/extract for manual
    /// installs, `brew upgrade --cask` streaming for Homebrew). The app stays
    /// alive throughout, with progress mirrored into `UpdateState`. When the
    /// pipeline reaches `readyToRestart`, the popover banner exposes a
    /// "Restart now" button that invokes `triggerRestart()`.
    private func triggerUpdateInstall() {
        // Re-entrancy guard: the user can hit "Install" multiple times across
        // the popover and Settings — only the first click should do work.
        if activeInstallTask != nil { return }
        guard let detector = installationDetector,
              let downloader = updateDownloader,
              let brewRunner = brewUpgradeRunner,
              let update = Self.sharedUpdateState.availableUpdate else {
            return
        }
        let detectedKind = Self.sharedUpdateState.installationKind ?? .manual
        let runningPath = Bundle.main.bundleURL.path
        // For manual installs, finalization needs an actual `.app` bundle path
        // — fine when running from /Applications/Foo.app, but `swift run` or
        // any ad-hoc binary lives in a flat directory. Prompt the user for an
        // installation directory and synthesize the target `.app` path.
        let bundlePath: String
        if detectedKind == .manual && !runningPath.hasSuffix(".app") {
            guard let chosen = Self.promptForInstallDirectory(startingAt: runningPath) else {
                return
            }
            bundlePath = (chosen as NSString).appendingPathComponent("\(Self.appBundleDisplayName).app")
        } else {
            bundlePath = runningPath
        }

        Self.sharedUpdateState.setPreparing()
        activeInstallBundlePath = bundlePath

        activeInstallTask = Task { [weak self] in
            do {
                // Resolve brew at install time too — the user may have just
                // installed Homebrew since the periodic check.
                let brewPath = await detector.brewExecutablePath()
                let effectiveKind: InstallationKind = (detectedKind == .homebrewCask && brewPath != nil) ? .homebrewCask : .manual
                await MainActor.run { self?.activeInstallKind = effectiveKind }

                switch effectiveKind {
                case .homebrewCask:
                    guard let brew = brewPath else {
                        // Should never happen given effectiveKind logic above,
                        // but bail safely rather than running brew with a nil path.
                        await MainActor.run { Self.sharedUpdateState.setFailed("Homebrew binary disappeared after detection.") }
                        return
                    }
                    try await brewRunner.runUpgrade(
                        brewExecutablePath: brew,
                        caskName: InstallationDetector.homebrewCaskName,
                        onEvent: { event in
                            Task { @MainActor in
                                if case .outputLine(let line) = event {
                                    Self.sharedUpdateState.setRunningHomebrew(lastLine: line)
                                }
                            }
                        }
                    )
                    // Brew has already swapped the bundle on disk — no staged path.
                    await MainActor.run { Self.sharedUpdateState.setReadyToRestart(stagedAppPath: nil) }

                case .manual:
                    let stagedURL = try await downloader.downloadAndStage(
                        update: update,
                        onEvent: { event in
                            Task { @MainActor in
                                Self.applyDownloadEvent(event)
                            }
                        }
                    )
                    await MainActor.run { Self.sharedUpdateState.setReadyToRestart(stagedAppPath: stagedURL.path) }
                }
            } catch is CancellationError {
                await MainActor.run { Self.sharedUpdateState.setFailed("Install cancelled.") }
            } catch {
                let message = String(describing: error)
                await MainActor.run { Self.sharedUpdateState.setFailed(message) }
            }
            // Clear the re-entrancy guard synchronously before returning so a
            // user clicking Retry immediately after a failure isn't dropped.
            await MainActor.run { self?.activeInstallTask = nil }
        }
    }

    /// Translates an `UpdateDownloadEvent` into a phase update.
    @MainActor
    private static func applyDownloadEvent(_ event: UpdateDownloadEvent) {
        switch event {
        case .progress(let received, let total):
            Self.sharedUpdateState.setDownloading(received: received, total: total)
        case .verifying:
            Self.sharedUpdateState.setVerifying()
        case .extracting:
            Self.sharedUpdateState.setExtracting()
        }
    }

    /// User clicked "Restart now": build a tiny finalize script (swap-and-relaunch
    /// for manual, relaunch-only for brew), launch it detached, then quit.
    private func triggerRestart() {
        guard let installer = updateInstaller,
              let update = Self.sharedUpdateState.availableUpdate,
              let bundlePath = activeInstallBundlePath,
              let kind = activeInstallKind else {
            return
        }
        let stagedAppPath = Self.sharedUpdateState.stagedAppPath
        Self.sharedUpdateState.setRestarting()
        let pid = ProcessInfo.processInfo.processIdentifier

        Task { [weak self] in
            do {
                let plan: UpdateFinalizationPlan
                switch kind {
                case .manual:
                    guard let staged = stagedAppPath else {
                        throw UpdateInstallerError.missingStagedApp(path: "(none)")
                    }
                    plan = try await installer.buildManualFinalizationPlan(
                        stagedAppPath: staged,
                        bundlePath: bundlePath,
                        currentPID: pid,
                        update: update
                    )
                case .homebrewCask:
                    plan = try await installer.buildHomebrewFinalizationPlan(
                        bundlePath: bundlePath,
                        currentPID: pid,
                        update: update
                    )
                }

                if plan.requiresAdminPrivileges {
                    let confirmed = await MainActor.run {
                        Self.confirmAdminElevation(version: update.version.rawValue)
                    }
                    guard confirmed else {
                        await MainActor.run {
                            Self.sharedUpdateState.setReadyToRestart(stagedAppPath: stagedAppPath)
                        }
                        return
                    }
                    try await Self.launchWithAdminPrivileges(scriptPath: plan.scriptPath)
                } else {
                    try Self.launchDetached(scriptPath: plan.scriptPath)
                }

                // Stop background work cleanly before terminating so the
                // finalize script (which polls our PID) sees a quick exit.
                await self?.gracefulShutdownAndTerminate()
            } catch {
                let message = String(describing: error)
                await MainActor.run { Self.sharedUpdateState.setFailed(message) }
            }
        }
    }

    /// Display name used to synthesize the install target when running from a
     /// non-`.app` location (e.g. `swift run`). Mirrors `scripts/build-app-bundle.sh`.
    private static let appBundleDisplayName = "AI Usages Tracker"

    /// Prompts the user for the directory in which to install the app. Returns
    /// nil if the user cancels. Defaults to the parent directory of the current
    /// binary, falling back to `/Applications` when that's a build artifact dir.
    @MainActor
    private static func promptForInstallDirectory(startingAt currentPath: String) -> String? {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.title = "Select installation directory"
        panel.message = "Choose where AI Usages Tracker should be installed."
        panel.prompt = "Install here"
        let parent = (currentPath as NSString).deletingLastPathComponent
        let defaultURL: URL
        if parent.contains("/.build/") || parent.hasSuffix("/.build") {
            defaultURL = URL(fileURLWithPath: "/Applications")
        } else {
            defaultURL = URL(fileURLWithPath: parent)
        }
        panel.directoryURL = defaultURL
        let previousPolicy = NSApp.activationPolicy()
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        defer { NSApp.setActivationPolicy(previousPolicy) }
        guard panel.runModal() == .OK else { return nil }
        return panel.url?.path
    }

    @MainActor
    private static func confirmAdminElevation(version: String) -> Bool {
        let alert = NSAlert()
        alert.icon = NSApplication.shared.applicationIconImage
        alert.messageText = "Administrator permission required"
        alert.informativeText = "AI Usages Tracker is installed in a location that requires administrator privileges to update. macOS will prompt you for your password to install version \(version)."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Continue")
        alert.addButton(withTitle: "Cancel")
        let previousPolicy = NSApp.activationPolicy()
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        defer { NSApp.setActivationPolicy(previousPolicy) }
        return alert.runModal() == .alertFirstButtonReturn
    }

    /// Launch the install script as root via AppleScript's
    /// `do shell script ... with administrator privileges`. The bash script is
    /// spawned in the background (`&`) so osascript exits as soon as the user
    /// approves the prompt — the script itself waits for the parent app to
    /// terminate before performing the actual swap.
    private static func launchWithAdminPrivileges(scriptPath: String) async throws {
        let escaped = scriptPath
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        let appleScript = """
        do shell script "/bin/bash \\"\(escaped)\\" >/dev/null 2>&1 &" with administrator privileges
        """
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            DispatchQueue.global().async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
                process.arguments = ["-e", appleScript]
                process.standardOutput = FileHandle.nullDevice
                process.standardError = FileHandle.nullDevice
                do {
                    try process.run()
                } catch {
                    continuation.resume(throwing: error)
                    return
                }
                process.waitUntilExit()
                guard process.terminationStatus == 0 else {
                    continuation.resume(throwing: NSError(
                        domain: "AIUsagesTracker.UpdateInstaller",
                        code: Int(process.terminationStatus),
                        userInfo: [NSLocalizedDescriptionKey: "Authorization was cancelled or denied (status \(process.terminationStatus))."]
                    ))
                    return
                }
                continuation.resume()
            }
        }
    }

    private func skipCurrentUpdate() {
        guard let version = Self.sharedUpdateState.availableUpdate?.version.rawValue else { return }
        Self.sharedUpdateState.dismissCurrent()
        var stored = Self.sharedPreferences.updatesDismissedVersions
        if !stored.contains(version) {
            stored.append(version)
            Self.sharedPreferences.updatesDismissedVersions = stored
        }
    }

    private func laterUpdate() {
        // No-op aside from clearing the in-popover banner this session.
        Self.sharedUpdateState.dismissCurrent()
    }

    private static func launchDetached(scriptPath: String) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [scriptPath]
        // Detach: redirect IO to /dev/null so the child outlives the app.
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        try process.run()
    }

    // MARK: - Quit

    private func quit() {
        // Trigger a clean async shutdown but don't block the main thread:
        // NSApp.terminate is invoked from the async closure once the actors
        // have settled. Falls back to an immediate terminate if the task
        // doesn't run within a short grace window (e.g. main thread starved).
        Task { [weak self] in
            await self?.gracefulShutdownAndTerminate()
        }
    }

    /// Awaits the actor stops, releases the PID guard, then asks AppKit to
    /// terminate. Used both by the menu's Quit item and by the update flow's
    /// "Restart now" path — in the latter case, the finalize script polls our
    /// PID, so a clean exit unblocks the swap quicker.
    @MainActor
    private func gracefulShutdownAndTerminate() async {
        let pollerRef = poller
        let schedulerRef = snapshotScheduler
        let monitors = VendorRegistry.bundles.compactMap(\.activeAccountMonitor)
        await pollerRef?.stop()
        await schedulerRef?.stop()
        for monitor in monitors {
            await monitor.stop()
        }
        usageStore?.stop()
        pidGuard?.release()
        NSApplication.shared.terminate(nil)
    }
}
