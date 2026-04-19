import SwiftUI
import AIUsagesTrackersLib

struct LoggingSettingsView: View {
    let preferences: any AppPreferences

    private var envOverrideActive: Bool {
        ProcessInfo.processInfo.environment["AI_TRACKER_LOG_LEVEL"] != nil
    }

    var body: some View {
        Form {
            Section {
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
