import SwiftUI
import AIUsagesTrackersLib

struct GeneralSettingsView: View {
    let preferences: any AppPreferences
    let launchAtLoginService: any LaunchAtLoginManaging

    @State private var launchAtLoginError: String?

    var body: some View {
        Form {
            Section("Polling") {
                let currentSeconds = preferences.refreshInterval.seconds
                HStack {
                    Text("Refresh interval")
                    Spacer()
                    Text("\(currentSeconds)s")
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
                Slider(
                    value: Binding(
                        get: { Double(currentSeconds) },
                        set: { preferences.refreshInterval = RefreshInterval(clamping: Int($0.rounded())) }
                    ),
                    in: Double(RefreshInterval.minimumSeconds)...Double(RefreshInterval.maximumSeconds),
                    step: 30
                ) {
                    Text("Refresh interval")
                } minimumValueLabel: {
                    Text("\(RefreshInterval.minimumSeconds)s")
                        .font(.caption)
                } maximumValueLabel: {
                    Text("\(RefreshInterval.maximumSeconds / 60)m")
                        .font(.caption)
                }
            }

            Section("Startup") {
                Toggle("Launch at login", isOn: Binding(
                    get: { preferences.launchAtLogin },
                    set: { newValue in
                        do {
                            try launchAtLoginService.setEnabled(newValue)
                            preferences.launchAtLogin = newValue
                            launchAtLoginError = nil
                        } catch {
                            launchAtLoginError = error.localizedDescription
                        }
                    }
                ))

                if let launchAtLoginError {
                    Text(launchAtLoginError)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }
        }
        .formStyle(.grouped)
    }
}
