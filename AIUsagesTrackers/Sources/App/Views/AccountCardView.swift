import SwiftUI
import AIUsagesTrackersLib

struct AccountCardView: View {
    let entry: VendorUsageEntry
    let isRefreshing: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                VendorIconView(vendor: entry.vendor, size: 13)

                Text(entry.account.rawValue)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)

                if isRefreshing {
                    ProgressView()
                        .controlSize(.small)
                        .scaleEffect(0.6)
                        .frame(width: 12, height: 12)
                }

                Spacer()

                if entry.isActive {
                    Text("active")
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.green, in: Capsule())
                }
            }

            ForEach(Array(entry.metrics.enumerated()), id: \.offset) { _, metric in
                metricRow(for: metric)
            }
        }
        .padding(10)
        .background(
            entry.isActive
                ? Color.green.opacity(0.20)
                : Color(NSColor.controlBackgroundColor),
            in: RoundedRectangle(cornerRadius: 8)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(Color.primary.opacity(0.20), lineWidth: 1)
        )
    }

    @ViewBuilder
    private func metricRow(for metric: UsageMetric) -> some View {
        switch metric {
        case let .timeWindow(name, resetAt, windowDuration, usagePercent):
            TimeWindowMetricRow(
                name: name,
                resetAt: resetAt,
                windowDuration: windowDuration,
                usagePercent: usagePercent
            )
        case let .payAsYouGo(name, currentAmount, currency):
            PayAsYouGoMetricRow(
                name: name,
                currentAmount: currentAmount,
                currency: currency
            )
        case .unknown:
            EmptyView()
        }
    }
}
