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

            HStack {
                Text(state.isUnknown ? "???" : formatRemainingTime(resetAt: resetAt!, now: now))
                    .font(.system(size: 10).monospacedDigit())
                    .foregroundStyle(.secondary)
                Spacer()
                Text(state.isUnknown ? "resets ???" : "resets \(formatResetDate(resetAt!, now: now))")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
        }
    }
}
