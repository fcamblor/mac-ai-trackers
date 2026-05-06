import AppKit
import SwiftUI
import AIUsagesTrackersLib
import AppIconKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var poller: UsagePoller?
    private var snapshotScheduler: SnapshotScheduler?
    private var accountMonitor: ClaudeActiveAccountMonitor?
    private var codexMonitor: CodexActiveAccountMonitor?
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
        let codexConnector = CodexConnector()
        let poller = UsagePoller(
            connectors: [ClaudeCodeConnector(), codexConnector],
            statusConnectors: [ClaudeStatusConnector(), CodexStatusConnector()],
            fileManager: fileManager,
            refreshState: refreshState,
            preferences: Self.sharedPreferences
        )
        let accountMonitor = ClaudeActiveAccountMonitor(
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
        let snapshotRecorder = SnapshotRecorder()
        let historyReader = UsageHistoryReader(rootPath: snapshotRecorder.rootPath)
        let snapshotScheduler = SnapshotScheduler(
            fileManager: fileManager,
            recorder: snapshotRecorder
        )
        self.poller = poller
        self.snapshotScheduler = snapshotScheduler
        self.accountMonitor = accountMonitor
        self.codexMonitor = codexMonitor
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
            await accountMonitor.start()
            await codexMonitor.start()
            if let scheduler = self.updateScheduler {
                await scheduler.start()
            }
        }
    }

    private func setupUpdateScheduler() {
        guard let currentVersion = Self.currentAppVersion() else {
            Loggers.app.log(.warning, "No CFBundleShortVersionString — update checker disabled")
            return
        }
        let bundlePath = Bundle.main.bundleURL.path
        let detector = InstallationDetector(bundlePath: bundlePath)
        self.installationDetector = detector
        self.updateInstaller = UpdateInstaller()
        let scheduler = UpdateScheduler(
            checker: UpdateChecker(),
            detector: detector,
            currentVersion: currentVersion,
            preferencesAccessor: { Self.sharedPreferences },
            stateAccessor: { Self.sharedUpdateState },
            onUpdateAvailable: { [weak self] update, kind in
                self?.presentUpdateAlert(update: update, kind: kind)
            }
        )
        self.updateScheduler = scheduler
        Self.sharedUpdateScheduler = scheduler
    }

    static func currentAppVersion() -> AppVersion? {
        guard let raw = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String else {
            return nil
        }
        return AppVersion(string: raw)
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

    private func triggerUpdateInstall() {
        guard let installer = updateInstaller,
              let detector = installationDetector,
              let update = Self.sharedUpdateState.availableUpdate else {
            return
        }
        Self.sharedUpdateState.setInstalling()
        let bundlePath = Bundle.main.bundleURL.path
        let installation = InstallationInfo(
            kind: Self.sharedUpdateState.installationKind ?? .manual,
            bundlePath: bundlePath
        )
        let pid = ProcessInfo.processInfo.processIdentifier
        Task { [weak self] in
            do {
                let brewPath = await detector.brewExecutablePath()
                let plan = try await installer.buildPlan(
                    for: update,
                    installation: installation,
                    brewExecutablePath: brewPath,
                    currentPID: pid
                )
                if plan.requiresAdminPrivileges {
                    let confirmed = await MainActor.run { Self.confirmAdminElevation(version: update.version.rawValue) }
                    guard confirmed else {
                        await MainActor.run { Self.sharedUpdateState.setIdle(checkedAt: Date()) }
                        return
                    }
                    try await Self.launchWithAdminPrivileges(scriptPath: plan.scriptPath)
                } else {
                    try Self.launchDetached(scriptPath: plan.scriptPath)
                }
                await MainActor.run {
                    self?.quit()
                }
            } catch {
                await MainActor.run {
                    let alert = NSAlert()
                    alert.messageText = "Failed to install update"
                    alert.informativeText = String(describing: error)
                    alert.runModal()
                    Self.sharedUpdateState.setError(String(describing: error), at: Date())
                }
            }
        }
    }

    @MainActor
    private static func confirmAdminElevation(version: String) -> Bool {
        let alert = NSAlert()
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
        let pollerRef = poller
        let schedulerRef = snapshotScheduler
        let monitorRef = accountMonitor
        let codexMonitorRef = codexMonitor
        Task {
            await pollerRef?.stop()
            await schedulerRef?.stop()
            await monitorRef?.stop()
            await codexMonitorRef?.stop()
        }
        usageStore?.stop()
        pidGuard?.release()
        NSApplication.shared.terminate(nil)
    }
}
