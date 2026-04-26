import SwiftUI
import AIUsagesTrackersLib

struct SettingsView: View {
    let launchAtLoginService: any LaunchAtLoginManaging

    var body: some View {
        // Access sharedPreferences directly so SwiftUI can observe the concrete
        // @Observable UserDefaultsAppPreferences type instead of the existential protocol.
        let preferences = AppDelegate.sharedPreferences

        return TabView {
            GeneralSettingsView(
                preferences: preferences,
                launchAtLoginService: launchAtLoginService
            )
            .tabItem { Label("General", systemImage: "gearshape") }

            MenubarHintSettingsView(preferences: preferences)
                .tabItem { Label("Menubar hint", systemImage: "menubar.rectangle") }

            ChartSettingsView(preferences: preferences)
                .tabItem { Label("Charts", systemImage: "chart.xyaxis.line") }

            // AssistantsSettingsView(preferences: preferences)
            //     .tabItem { Label("Assistants", systemImage: "sparkles") }
        }
        .frame(minWidth: 680, idealWidth: 720, minHeight: 750, idealHeight: 800)
    }
}
