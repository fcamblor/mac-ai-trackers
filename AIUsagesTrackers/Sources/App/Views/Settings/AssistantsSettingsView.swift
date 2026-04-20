import SwiftUI
import AIUsagesTrackersLib

struct AssistantsSettingsView: View {
    let preferences: any AppPreferences

    private static let pollingStepsMinutes: [Int] = [1, 2, 3, 5, 10]

    private var selectedStepIndex: Binding<Double> {
        Binding(
            get: {
                let minutes = preferences.refreshInterval.seconds / 60
                let idx = Self.pollingStepsMinutes.firstIndex(of: minutes)
                    ?? Self.closestStepIndex(for: minutes)
                return Double(idx)
            },
            set: { newValue in
                let idx = min(max(Int(newValue.rounded()), 0), Self.pollingStepsMinutes.count - 1)
                let minutes = Self.pollingStepsMinutes[idx]
                preferences.refreshInterval = RefreshInterval(clamping: minutes * 60)
            }
        )
    }

    private static func closestStepIndex(for minutes: Int) -> Int {
        var best = 0
        var bestDelta = Int.max
        for (idx, step) in pollingStepsMinutes.enumerated() {
            let delta = abs(step - minutes)
            if delta < bestDelta {
                best = idx
                bestDelta = delta
            }
        }
        return best
    }

    private var currentMinutesLabel: String {
        let minutes = preferences.refreshInterval.seconds / 60
        return minutes == 1 ? "1 minute" : "\(minutes) minutes"
    }

    // Approximate macOS Slider thumb radius — used to inset tick labels so they
    // align with the thumb's travel range rather than the slider's outer bounds.
    private static let sliderThumbRadius: CGFloat = 11

    var body: some View {
        Form {
            Section("Claude") {
                VStack(alignment: .leading, spacing: 4) {
                    Slider(
                        value: selectedStepIndex,
                        in: 0...Double(Self.pollingStepsMinutes.count - 1),
                        step: 1
                    ) {
                        Text("API polling interval")
                    }
                    GeometryReader { geo in
                        ZStack(alignment: .topLeading) {
                            ForEach(Array(Self.pollingStepsMinutes.enumerated()), id: \.offset) { idx, minutes in
                                let fraction = CGFloat(idx) / CGFloat(Self.pollingStepsMinutes.count - 1)
                                Text("\(minutes)m")
                                    .font(.caption2)
                                    .foregroundStyle(.tertiary)
                                    .fixedSize()
                                    .position(x: geo.size.width * fraction, y: 8)
                            }
                        }
                    }
                    .frame(height: 16)
                    .padding(.horizontal, Self.sliderThumbRadius)
                    Text("Fetching every \(currentMinutesLabel) from the Claude API.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
    }
}
