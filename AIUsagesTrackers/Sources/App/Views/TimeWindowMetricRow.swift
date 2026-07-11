import SwiftUI
import AIUsagesTrackersLib

/// Displays a time-window metric: name, gauge bar with theoretical marker,
/// percentage, remaining time, and next reset date.
struct TimeWindowMetricRow: View {
    let name: String
    let resetAt: ISODate?
    let windowDuration: DurationMinutes
    let usagePercent: UsagePercent
    let subtitle: String?

    @State private var isSubtitleExpanded = false

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
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(name)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)
                    if let subtitle {
                        subtitleView(subtitle)
                    }
                }
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
                    .italic()
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

    @ViewBuilder
    private func subtitleView(_ subtitle: String) -> some View {
        // Tap-to-expand: collapsed shows a single ellipsised line, tapping
        // anywhere on the row (including the trailing empty space) expands
        // the text over as many lines as it needs. Cheaper than a separate
        // "Show all" affordance and avoids the toggle reserving space when
        // the subtitle would have fit on one line anyway.
        HStack(spacing: 0) {
            Text(subtitle)
                .font(.system(size: 9, weight: .regular))
                .italic()
                .foregroundStyle(.secondary)
                .lineLimit(isSubtitleExpanded ? nil : 1)
                .truncationMode(.tail)
                .fixedSize(horizontal: false, vertical: isSubtitleExpanded)
            Spacer(minLength: 0)
        }
        .contentShape(Rectangle())
        .onTapGesture {
            isSubtitleExpanded.toggle()
        }
    }
}
