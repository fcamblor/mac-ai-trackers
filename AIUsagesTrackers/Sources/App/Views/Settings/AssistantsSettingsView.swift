import SwiftUI
import AIUsagesTrackersLib

struct AssistantsSettingsView: View {
    let preferences: any AppPreferences

    var body: some View {
        Form {
            Section("Vendor API") {
                UsageDataRefreshIntervalView()
            }
        }
        .formStyle(.grouped)
    }
}
