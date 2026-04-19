import SwiftUI
import AIUsagesTrackersLib

struct SettingsView: View {
    let preferences: any AppPreferences
    let launchAtLoginService: any LaunchAtLoginManaging

    var body: some View {
        TabView {
            GeneralSettingsView(
                preferences: preferences,
                launchAtLoginService: launchAtLoginService
            )
            .tabItem { Label("General", systemImage: "gearshape") }

            LoggingSettingsView(preferences: preferences)
                .tabItem { Label("Logging", systemImage: "doc.text") }
        }
        .frame(width: 400)
    }
}
