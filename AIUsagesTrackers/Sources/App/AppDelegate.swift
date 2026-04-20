import AppKit
import SwiftUI
import AIUsagesTrackersLib

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var poller: UsagePoller?
    private var accountMonitor: ClaudeActiveAccountMonitor?
    private var pidGuard: AppPidGuard?
    private var usageStore: UsageStore?
    private var refreshState: RefreshState?
    private var statusItem: NSStatusItem?
    private var popover: NSPopover?
    private var appearanceObserver: NSKeyValueObservation?
    private var settingsWindowObserver: NSObjectProtocol?

    /// Shared preferences store — exposed as static so the SwiftUI Settings scene
    /// (constructed before applicationDidFinishLaunching) can access it.
    static let sharedPreferences: UserDefaultsAppPreferences = UserDefaultsAppPreferences()

    /// Shared usage store — populated in applicationDidFinishLaunching. The Settings
    /// scene is instantiated before the store exists, so it must read through this
    /// mutable holder. Nil until the first launch callback has run.
    static var sharedStore: UsageStore?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApplication.shared.setActivationPolicy(.accessory)

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

        // Reconcile launch-at-login preference with system state — the user may
        // have disabled the entry in System Settings > Login Items directly.
        let launchService = LaunchAtLoginService.shared
        if Self.sharedPreferences.launchAtLogin != launchService.isEnabled {
            Self.sharedPreferences.launchAtLogin = launchService.isEnabled
        }

        let fileManager = UsagesFileManager.shared
        let refreshState = RefreshState()
        let poller = UsagePoller(
            connectors: [ClaudeCodeConnector()],
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
        self.poller = poller
        self.accountMonitor = accountMonitor
        self.refreshState = refreshState

        let usagesPath = fileManager.filePath
        let fileWatcher = UsagesFileWatcher(path: usagesPath)
        let store = UsageStore(fileWatcher: fileWatcher, preferences: Self.sharedPreferences)
        self.usageStore = store
        Self.sharedStore = store

        setupStatusItem(store: store, refreshState: refreshState)
        trackStoreChanges(store: store)

        Task {
            store.start()
            await poller.start()
            await accountMonitor.start()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        quit()
    }

    // MARK: - Status item

    private func setupStatusItem(store: UsageStore, refreshState: RefreshState) {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem = item

        let popover = NSPopover()
        popover.behavior = .transient
        let hosting = NSHostingController(
            rootView: UsageDetailsView(
                store: store,
                refreshState: refreshState,
                onRefresh: { [weak self] in
                    await self?.poller?.pollOnce(now: Date(), force: true)
                },
                onOpenSettings: { [weak self] in
                    self?.openSettings()
                },
                onQuit: { [weak self] in
                    self?.quit()
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
        let image = MenuBarLabelRenderer.render(
            segments: store.menuBarSegments,
            fallbackText: store.menuBarText,
            isDarkMenuBar: isDark
        )
        button.image = image
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
        withObservationTracking {
            _ = store.menuBarSegments
            _ = store.menuBarText
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
            settingsWindowObserver = NotificationCenter.default.addObserver(
                forName: NSWindow.willCloseNotification,
                object: nil,
                queue: .main
            ) { [weak self] notification in
                guard let self else { return }
                // Only react to the Settings window closing — popovers and other
                // transient windows also emit willClose.
                guard let closingWindow = notification.object as? NSWindow else { return }
                let windowIdentifier = closingWindow.identifier?.rawValue ?? ""
                guard windowIdentifier.contains("Settings") || windowIdentifier.contains("Preferences") else { return }
                // willClose fires while the window is still visible and before
                // AppKit tears it down; defer to the next runloop tick so the
                // activation-policy change isn't overridden by pending AppKit work.
                DispatchQueue.main.async {
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
                    if let token = self.settingsWindowObserver {
                        NotificationCenter.default.removeObserver(token)
                        self.settingsWindowObserver = nil
                    }
                }
            }
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

    // MARK: - Quit

    private func quit() {
        let pollerRef = poller
        let monitorRef = accountMonitor
        Task {
            await pollerRef?.stop()
            await monitorRef?.stop()
        }
        usageStore?.stop()
        pidGuard?.release()
        NSApplication.shared.terminate(nil)
    }
}
