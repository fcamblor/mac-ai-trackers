import SwiftUI
import AIUsagesTrackersLib

/// Displays a time-window metric: name, gauge bar with theoretical marker,
/// percentage, remaining time, and next reset date.
struct TimeWindowMetricRow: View {
    let name: String
    let resetAt: ISODate
    let windowDuration: DurationMinutes
    let usagePercent: UsagePercent

    private var actualFraction: Double {
        Double(usagePercent.rawValue) / 100.0
    }

    var body: some View {
        let now = Date()
        let theoretical = theoreticalFraction(resetAt: resetAt, windowDuration: windowDuration, now: now)
        let tier = consumptionRatio(actualPercent: usagePercent, theoreticalFraction: theoretical)
            .map(consumptionTier(ratio:))

        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(name.capitalized)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                Spacer()
                Text("\(usagePercent.rawValue)%")
                    .font(.system(size: 11, weight: .semibold).monospacedDigit())
            }

            GaugeBar(
                actual: actualFraction,
                theoretical: theoretical,
                tier: tier
            )

            HStack {
                Text(formatRemainingTime(resetAt: resetAt, now: now))
                    .font(.system(size: 10).monospacedDigit())
                    .foregroundStyle(.secondary)
                Spacer()
                Text("resets \(formatResetDate(resetAt, now: now))")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
        }
    }
}
