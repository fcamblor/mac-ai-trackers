import SwiftUI
import AppKit

@main
struct AIUsagesTrackersApp: App {
    init() {
        NSApplication.shared.setActivationPolicy(.accessory)
    }

    var body: some Scene {
        MenuBarExtra {
            Text("Hello World")
            Divider()
            Button("Quit") {
                NSApplication.shared.terminate(nil)
            }
            .keyboardShortcut("q")
        } label: {
            Text("Hello World")
        }
    }
}
