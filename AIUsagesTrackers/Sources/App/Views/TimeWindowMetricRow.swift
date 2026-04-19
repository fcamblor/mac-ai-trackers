import SwiftUI
import AIUsagesTrackersLib

/// Displays a time-window metric: name, gauge bar with theoretical marker,
/// percentage, remaining time, and next reset date.
struct TimeWindowMetricRow: View {
    let name: String
    let resetAt: ISODate?
    let windowDuration: DurationMinutes
    let usagePercent: UsagePercent

    private var actualFraction: Double {
        Double(usagePercent.rawValue) / 100.0
    }

    var body: some View {
        // TimelineView re-renders every minute so remaining time and theoretical
        // consumption stay accurate even when no network refresh occurs.
        TimelineView(.periodic(from: .now, by: 60)) { context in
            content(now: context.date)
        }
    }

    @ViewBuilder
    private func content(now: Date) -> some View {
        // nil resetAt (no active window yet) is treated identically to an expired window
        let isUnknown = resetAt.flatMap { $0.date.map { now > $0 } } ?? true
        let theoretical = isUnknown ? 0.0 : theoreticalFraction(resetAt: resetAt!, windowDuration: windowDuration, now: now)
        let tier = consumptionRatio(actualPercent: usagePercent, theoreticalFraction: theoretical)
            .map(consumptionTier(ratio:))

        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(name)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                Spacer()
                Text(isUnknown ? "???" : "\(usagePercent.rawValue)%")
                    .font(.system(size: 11, weight: .semibold).monospacedDigit())
            }

            GaugeBar(
                actual: isUnknown ? 0.0 : actualFraction,
                theoretical: theoretical,
                tier: tier
            )

            HStack {
                Text(isUnknown ? "???" : formatRemainingTime(resetAt: resetAt!, now: now))
                    .font(.system(size: 10).monospacedDigit())
                    .foregroundStyle(.secondary)
                Spacer()
                Text(isUnknown ? "resets ???" : "resets \(formatResetDate(resetAt!, now: now))")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
        }
    }
}
