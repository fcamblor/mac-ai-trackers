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

            MenubarHintSettingsView(preferences: preferences)
                .tabItem { Label("Menubar hint", systemImage: "menubar.rectangle") }

            AssistantsSettingsView(preferences: preferences)
                .tabItem { Label("Assistants", systemImage: "sparkles") }
        }
        .frame(width: 520)
    }
}
