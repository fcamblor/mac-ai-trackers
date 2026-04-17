import SwiftUI
import AppKit
import AIUsagesTrackersLib

@main
struct AIUsagesTrackersApp: App {
    private let poller: UsagePoller

    init() {
        NSApplication.shared.setActivationPolicy(.accessory)
        poller = UsagePoller(connectors: [ClaudeCodeConnector()])
        // pollerRef captures the actor value before self is fully available in the Task closure
        let pollerRef = poller
        Task { await pollerRef.start() }
    }

    var body: some Scene {
        MenuBarExtra {
            Text("AI Usages Tracker")
            Divider()
            Button("Quit") {
                Task {
                    await poller.stop()
                    await MainActor.run { NSApplication.shared.terminate(nil) }
                }
            }
            .keyboardShortcut("q")
        } label: {
            Text("AI Tracker")
        }
    }
}
