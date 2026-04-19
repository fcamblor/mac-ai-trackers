import AppKit
import SwiftUI
import AIUsagesTrackersLib

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var logCleaner: LogCleaner?
    private var poller: UsagePoller?
    private var accountMonitor: ClaudeActiveAccountMonitor?
    private var pidGuard: AppPidGuard?
    private var usageStore: UsageStore?
    private var refreshState: RefreshState?
    private var statusItem: NSStatusItem?
    private var popover: NSPopover?
    private var appearanceObserver: NSKeyValueObservation?

    /// Shared preferences store — exposed as static so the SwiftUI Settings scene
    /// (constructed before applicationDidFinishLaunching) can access it.
    static let sharedPreferences: UserDefaultsAppPreferences = UserDefaultsAppPreferences()

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
        let logCleaner = LogCleaner()
        self.logCleaner = logCleaner
        self.poller = poller
        self.accountMonitor = accountMonitor
        self.refreshState = refreshState

        let usagesPath = fileManager.filePath
        let fileWatcher = UsagesFileWatcher(path: usagesPath)
        let store = UsageStore(fileWatcher: fileWatcher)
        self.usageStore = store

        setupStatusItem(store: store, refreshState: refreshState)
        trackStoreChanges(store: store)

        Task {
            await logCleaner.start()
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
        popover.contentSize = NSSize(width: 320, height: 400)
        popover.contentViewController = NSHostingController(
            rootView: UsageDetailsView(
                store: store,
                refreshState: refreshState,
                onRefresh: { [weak self] in
                    await self?.poller?.pollOnce(now: Date(), force: true)
                },
                onQuit: { [weak self] in
                    self?.quit()
                }
            )
        )
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

    // MARK: - Quit

    private func quit() {
        let logCleanerRef = logCleaner
        let pollerRef = poller
        let monitorRef = accountMonitor
        Task {
            await logCleanerRef?.stop()
            await pollerRef?.stop()
            await monitorRef?.stop()
        }
        usageStore?.stop()
        pidGuard?.release()
        NSApplication.shared.terminate(nil)
    }
}
