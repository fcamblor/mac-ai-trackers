import SwiftUI
import AppKit
import AIUsagesTrackersLib

@main
struct AIUsagesTrackersApp: App {
    private let poller: UsagePoller
    private let accountMonitor: ClaudeActiveAccountMonitor
    private let pidGuard: AppPidGuard
    @State private var usageStore: UsageStore

    init() {
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
            fatalError("terminate() did not exit")
        } catch {
            let alert = NSAlert()
            alert.messageText = "Failed to start AI Usages Tracker"
            alert.informativeText = error.localizedDescription
            alert.runModal()
            NSApplication.shared.terminate(nil)
            fatalError("terminate() did not exit")
        }
        pidGuard = guard_

        let fileManager = UsagesFileManager.shared
        poller = UsagePoller(connectors: [ClaudeCodeConnector()], fileManager: fileManager)
        accountMonitor = ClaudeActiveAccountMonitor(fileManager: fileManager)

        let usagesPath = fileManager.filePath
        let fileWatcher = UsagesFileWatcher(path: usagesPath)
        let store = UsageStore(fileWatcher: fileWatcher)
        _usageStore = State(initialValue: store)

        let pollerRef = poller
        let monitorRef = accountMonitor
        Task { @MainActor in
            store.start()
            await pollerRef.start()
            await monitorRef.start()
        }
    }

    var body: some Scene {
        MenuBarExtra {
            UsageDetailsView(store: usageStore) {
                Task {
                    await poller.stop()
                    await accountMonitor.stop()
                }
                usageStore.stop()
                pidGuard.release()
                NSApplication.shared.terminate(nil)
            }
        } label: {
            Text(usageStore.menuBarText)
        }
        .menuBarExtraStyle(.window)
    }
}
