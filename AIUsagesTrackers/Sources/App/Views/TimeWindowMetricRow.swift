import SwiftUI
import AIUsagesTrackersLib

/// Displays a time-window metric: name, gauge bar with theoretical marker,
/// percentage, remaining time, and next reset date.
struct TimeWindowMetricRow: View {
    let name: String
    let resetAt: ISODate?
    let windowDuration: DurationMinutes
    let usagePercent: UsagePercent

    var body: some View {
        // TimelineView re-renders every minute so remaining time and theoretical
        // consumption stay accurate even when no network refresh occurs.
        TimelineView(.periodic(from: .now, by: 60)) { context in
            content(now: context.date)
        }
    }

    @ViewBuilder
    private func content(now: Date) -> some View {
        // Single source of truth shared with MenuBarSegmentResolver — see
        // TimeWindowVisualState. Do NOT recompute isUnknown / tier locally.
        let state = TimeWindowVisualState(
            resetAt: resetAt,
            windowDuration: windowDuration,
            usagePercent: usagePercent,
            now: now
        )

        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(name)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                Spacer()
                Text(state.isUnknown ? "???" : "\(usagePercent.rawValue)%")
                    .font(.system(size: 11, weight: .semibold).monospacedDigit())
            }

            GaugeBar(
                actual: state.actualFraction,
                theoretical: state.elapsedFraction,
                tier: state.tier
            )

            if state.isUnknown {
                // No window opened yet: percent and reset time have no
                // denominator to anchor them, so we explain the state in
                // plain text rather than echoing "???" on every field.
                Text("Window opens with your next request — usage and reset time will appear then.")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                HStack {
                    Text(formatRemainingTime(resetAt: resetAt!, now: now))
                        .font(.system(size: 10).monospacedDigit())
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text("resets \(formatResetDate(resetAt!, now: now))")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
            }
        }
    }
}
