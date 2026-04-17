import SwiftUI
import AppKit

@main
struct AIUsagesTrackersApp: App {
    private let poller: UsagePoller

    init() {
        NSApplication.shared.setActivationPolicy(.accessory)
        poller = UsagePoller(connectors: [ClaudeCodeConnector()])
        let pollerRef = poller
        Task { await pollerRef.start() }
    }

    var body: some Scene {
        MenuBarExtra {
            Text("AI Usages Tracker")
            Divider()
            Button("Quit") {
                Task { await poller.stop() }
                NSApplication.shared.terminate(nil)
            }
            .keyboardShortcut("q")
        } label: {
            Text("AI Tracker")
        }
    }
}
