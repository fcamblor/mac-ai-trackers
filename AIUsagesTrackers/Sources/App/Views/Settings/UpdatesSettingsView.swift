import SwiftUI
import AIUsagesTrackersLib

struct UpdatesSettingsView: View {
    let preferences: any AppPreferences
    let updateState: UpdateState

    private static let lastCheckedFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        return f
    }()

    var body: some View {
        let prefs = AppDelegate.sharedPreferences
        Form {
            Section("Automatic updates") {
                Toggle("Check for updates automatically", isOn: Binding(
                    get: { prefs.updatesAutoCheckEnabled },
                    set: { prefs.updatesAutoCheckEnabled = $0 }
                ))
                Text("When enabled, AI Usages Tracker checks GitHub for new releases at startup and every six hours.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Manual check") {
                HStack {
                    Button("Check now") {
                        Task {
                            await AppDelegate.sharedUpdateScheduler?.checkNow()
                        }
                    }
                    .disabled(updateState.phase == .checking)

                    if updateState.phase == .checking {
                        ProgressView().controlSize(.small).scaleEffect(0.7)
                    }
                    Spacer()
                    if let last = updateState.lastCheckedAt {
                        Text("Last checked \(Self.lastCheckedFormatter.string(from: last))")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                if let pending = updateState.pendingUpdate {
                    Text("Version \(pending.version.rawValue) is available.")
                        .font(.caption)
                        .foregroundStyle(.green)
                } else if updateState.lastError != nil {
                    Text("Last check failed: \(updateState.lastError ?? "")")
                        .font(.caption)
                        .foregroundStyle(.red)
                } else if updateState.lastCheckedAt != nil {
                    Text("You are up to date.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            if !prefs.updatesDismissedVersions.isEmpty {
                Section("Skipped versions") {
                    ForEach(prefs.updatesDismissedVersions, id: \.self) { version in
                        HStack {
                            Text(version).font(.system(size: 12))
                            Spacer()
                            Button(role: .destructive) {
                                prefs.updatesDismissedVersions.removeAll { $0 == version }
                                updateState.dismissedVersions.remove(version)
                            } label: {
                                Image(systemName: "trash")
                            }
                            .buttonStyle(.borderless)
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
    }
}
