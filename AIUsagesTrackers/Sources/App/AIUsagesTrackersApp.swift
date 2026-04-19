import SwiftUI
import AIUsagesTrackersLib

@main
struct AIUsagesTrackersApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        Settings {
            SettingsView(
                preferences: AppDelegate.sharedPreferences,
                launchAtLoginService: LaunchAtLoginService.shared
            )
        }
    }
}
