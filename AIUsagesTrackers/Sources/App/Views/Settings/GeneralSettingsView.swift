import SwiftUI
import AIUsagesTrackersLib

struct GeneralSettingsView: View {
    let preferences: any AppPreferences
    let launchAtLoginService: any LaunchAtLoginManaging

    @State private var launchAtLoginError: String?

    private var envOverrideActive: Bool {
        ProcessInfo.processInfo.environment["AI_TRACKER_LOG_LEVEL"] != nil
    }

    var body: some View {
        Form {
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

            Section("Logging") {
                Picker("Log level", selection: Binding(
                    get: { preferences.logLevel },
                    set: { preferences.logLevel = $0 }
                )) {
                    Text("Debug").tag(LogLevel.debug)
                    Text("Info").tag(LogLevel.info)
                    Text("Warning").tag(LogLevel.warning)
                    Text("Error").tag(LogLevel.error)
                }
                .disabled(envOverrideActive)

                if envOverrideActive {
                    Text("Log level is overridden by the AI_TRACKER_LOG_LEVEL environment variable.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
    }
}
