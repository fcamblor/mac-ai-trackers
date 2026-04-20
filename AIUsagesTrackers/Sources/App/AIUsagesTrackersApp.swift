import SwiftUI
import AIUsagesTrackersLib

@main
struct AIUsagesTrackersApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        Settings {
            SettingsView(
                launchAtLoginService: LaunchAtLoginService.shared
            )
        }
    }
}
