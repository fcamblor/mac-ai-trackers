import SwiftUI
import AppKit
import AIUsagesTrackersLib

@main
struct AIUsagesTrackersApp: App {
    private let poller: UsagePoller
    private let accountMonitor: ClaudeActiveAccountMonitor
    private let pidGuard: AppPidGuard

    init() {
        NSApplication.shared.setActivationPolicy(.accessory)

        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let guard_ = AppPidGuard(cacheDir: "\(home)/.cache/ai-usages-tracker")
        do {
            try guard_.acquire()
        } catch {
            let alert = NSAlert()
            alert.messageText = "Already running"
            alert.informativeText = error.localizedDescription
            alert.runModal()
            NSApplication.shared.terminate(nil)
            fatalError("terminate() did not exit")
        }
        pidGuard = guard_

        let fileManager = UsagesFileManager.shared
        poller = UsagePoller(connectors: [ClaudeCodeConnector()], fileManager: fileManager)
        accountMonitor = ClaudeActiveAccountMonitor(fileManager: fileManager)

        let pollerRef = poller
        let monitorRef = accountMonitor
        Task {
            await pollerRef.start()
            await monitorRef.start()
        }
    }

    var body: some Scene {
        MenuBarExtra {
            Text("AI Usages Tracker")
            Divider()
            Button("Quit") {
                Task {
                    await poller.stop()
                    await accountMonitor.stop()
                }
                pidGuard.release()
                NSApplication.shared.terminate(nil)
            }
            .keyboardShortcut("q")
        } label: {
            Text("AI Tracker")
        }
    }
}
