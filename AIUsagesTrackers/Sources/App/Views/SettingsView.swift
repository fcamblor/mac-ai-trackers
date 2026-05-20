import SwiftUI
import AIUsagesTrackersLib

struct SettingsView: View {
    let launchAtLoginService: any LaunchAtLoginManaging

    @State private var router = SettingsRouter.shared

    var body: some View {
        // Access sharedPreferences directly so SwiftUI can observe the concrete
        // @Observable UserDefaultsAppPreferences type instead of the existential protocol.
        let preferences = AppDelegate.sharedPreferences

        return TabView(selection: $router.selectedTab) {
            GeneralSettingsView(
                preferences: preferences,
                launchAtLoginService: launchAtLoginService
            )
            .tabItem { Label("General", systemImage: "gearshape") }
            .tag(SettingsTab.general)

            AssistantsSettingsView(preferences: preferences)
                .tabItem { Label("Coding Assistants", systemImage: "sparkles") }
                .tag(SettingsTab.codingAssistants)

            MenubarHintSettingsView(preferences: preferences)
                .tabItem { Label("Menubar hint", systemImage: "menubar.rectangle") }
                .tag(SettingsTab.menubarHint)

            ChartSettingsView(preferences: preferences)
                .tabItem { Label("Charts", systemImage: "chart.xyaxis.line") }
                .tag(SettingsTab.charts)

            if let registry = AppDelegate.sharedCodexStatusRegistry {
                StatusSettingsView(preferences: preferences, registry: registry)
                    .tabItem { Label("Status", systemImage: "exclamationmark.triangle") }
                    .tag(SettingsTab.status)
            }

            UpdatesSettingsView(
                preferences: preferences,
                updateState: AppDelegate.sharedUpdateState
            )
            .tabItem { Label("Updates", systemImage: "arrow.down.circle") }
            .tag(SettingsTab.updates)
        }
        .frame(minWidth: 680, idealWidth: 720, minHeight: 750, idealHeight: 800)
    }
}
