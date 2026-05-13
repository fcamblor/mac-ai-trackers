import SwiftUI
import AIUsagesTrackersLib

struct StatusSettingsView: View {
    let preferences: any AppPreferences
    let registry: StatusComponentRegistry

    @State private var components: [StatusComponent] = []
    @State private var lastRefreshedAt: ISODate?
    @State private var isRefreshing = false
    @State private var refreshError: String?

    var body: some View {
        Form {
            Section("Codex components") {
                Text("Codex outage banners only surface when an incident affects at least one subscribed component.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if components.isEmpty {
                    Text("No components discovered yet. Click \"Refresh now\" to fetch the current list from status.openai.com.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(components) { component in
                        Toggle(isOn: subscriptionBinding(for: component)) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(component.name)
                                    .font(.system(size: 13))
                                Text(component.id.rawValue)
                                    .font(.system(size: 10, design: .monospaced))
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }

            Section("Refresh") {
                HStack {
                    if let lastRefreshedAt {
                        Text("Last refreshed: \(lastRefreshedAt.rawValue)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        Text("Last refreshed: never")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Refresh now") {
                        Task { await performRefresh() }
                    }
                    .disabled(isRefreshing)
                }

                if let refreshError {
                    Text(refreshError)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }
        }
        .formStyle(.grouped)
        .task { await loadCached() }
    }

    private func subscriptionBinding(for component: StatusComponent) -> Binding<Bool> {
        Binding(
            get: { preferences.statusComponentSubscriptions[component.id.rawValue] ?? true },
            set: { newValue in
                var current = preferences.statusComponentSubscriptions
                if newValue {
                    current.removeValue(forKey: component.id.rawValue)
                } else {
                    current[component.id.rawValue] = false
                }
                preferences.statusComponentSubscriptions = current
            }
        )
    }

    private func loadCached() async {
        guard let entry = await registry.cachedEntry() else { return }
        self.components = entry.components
        self.lastRefreshedAt = entry.lastRefreshedAt
    }

    private func performRefresh() async {
        isRefreshing = true
        refreshError = nil
        defer { isRefreshing = false }
        do {
            let entry = try await registry.refresh()
            self.components = entry.components
            self.lastRefreshedAt = entry.lastRefreshedAt
        } catch {
            refreshError = String(describing: error)
        }
    }
}
