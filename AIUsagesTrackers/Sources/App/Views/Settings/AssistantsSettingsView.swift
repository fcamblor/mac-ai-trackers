import SwiftUI
import AIUsagesTrackersLib

struct AssistantsSettingsView: View {
    let preferences: any AppPreferences

    private static let pollingStepsMinutes: [Int] = [1, 2, 3, 5, 10]

    private func selectedStepIndex(with concretePrefs: UserDefaultsAppPreferences) -> Binding<Double> {
        Binding(
            get: {
                let minutes = concretePrefs.refreshInterval.seconds / 60
                let idx = Self.pollingStepsMinutes.firstIndex(of: minutes)
                    ?? Self.closestStepIndex(for: minutes)
                return Double(idx)
            },
            set: { newValue in
                let idx = min(max(Int(newValue.rounded()), 0), Self.pollingStepsMinutes.count - 1)
                let minutes = Self.pollingStepsMinutes[idx]
                concretePrefs.refreshInterval = RefreshInterval(clamping: minutes * 60)
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

    private func currentMinutesLabel(from concretePrefs: UserDefaultsAppPreferences) -> String {
        let minutes = concretePrefs.refreshInterval.seconds / 60
        return minutes == 1 ? "1 minute" : "\(minutes) minutes"
    }

    // Half-width of the macOS SwiftUI Slider thumb. Tick labels are inset by this
    // amount so their centres match the thumb's travel range, not the slider's
    // outer bounds (where the thumb never reaches).
    private static let sliderThumbRadius: CGFloat = 10

    var body: some View {
        // Access concrete preferences to enable SwiftUI observation tracking.
        let concretePrefs = AppDelegate.sharedPreferences

        return Form {
            Section("Claude") {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(alignment: .firstTextBaseline) {
                        Text("API polling interval")
                        Spacer()
                        Text(currentMinutesLabel(from: concretePrefs))
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                    Slider(
                        value: selectedStepIndex(with: concretePrefs),
                        in: 0...Double(Self.pollingStepsMinutes.count - 1),
                        step: 1
                    ) {
                        EmptyView()
                    }
                    .labelsHidden()
                    GeometryReader { geo in
                        let travel = max(0, geo.size.width - 2 * Self.sliderThumbRadius)
                        ZStack(alignment: .topLeading) {
                            ForEach(Array(Self.pollingStepsMinutes.enumerated()), id: \.offset) { idx, minutes in
                                let fraction = CGFloat(idx) / CGFloat(Self.pollingStepsMinutes.count - 1)
                                Text("\(minutes)m")
                                    .font(.caption2)
                                    .foregroundStyle(.tertiary)
                                    .fixedSize()
                                    .position(x: Self.sliderThumbRadius + travel * fraction, y: 8)
                            }
                        }
                    }
                    .frame(height: 16)
                    Text("How often usage data is fetched from the Claude API.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
    }
}
