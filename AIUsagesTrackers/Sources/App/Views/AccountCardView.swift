import SwiftUI
import AIUsagesTrackersLib

struct AccountCardView: View {
    let entry: VendorUsageEntry
    let isRefreshing: Bool
    var onIgnore: (() -> Void)? = nil

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

            if let lastError = entry.lastError {
                errorRow(for: lastError)
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
        .contextMenu {
            if let onIgnore {
                Button("Ignore this account") { onIgnore() }
            }
        }
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

    private func errorRow(for error: UsageError) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.orange)
                .frame(width: 12, height: 12)

            VStack(alignment: .leading, spacing: 2) {
                Text(errorTitle(for: error.type))
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.primary)
                    .fixedSize(horizontal: false, vertical: true)
                Text(errorDetail(for: error.type))
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 6))
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .strokeBorder(Color.orange.opacity(0.35), lineWidth: 1)
        )
    }

    private func errorTitle(for type: String) -> String {
        switch type {
        case "api_key_usage_unsupported":
            "Usage unavailable with API key auth"
        case "token_error":
            "Authentication unavailable"
        case "token_expired":
            "Session expired"
        case "api_error":
            "Usage refresh failed"
        case "parse_error":
            "Unexpected usage response"
        case "account_unknown":
            "Account not detected"
        case "http_429":
            "Usage refresh rate-limited"
        default:
            if type.hasPrefix("http_") {
                "Usage refresh failed"
            } else {
                "Usage issue"
            }
        }
    }

    private func errorDetail(for type: String) -> String {
        switch type {
        case "api_key_usage_unsupported":
            "Claude standard API keys cannot expose usage here. Claude Code OAuth credentials are required."
        case "token_error":
            "Credentials could not be read from the expected local source."
        case "token_expired":
            "Re-authenticate with the vendor CLI, then refresh."
        case "api_error":
            "Network or API request failed. Last known metrics may be stale."
        case "parse_error":
            "The vendor response shape changed or was incomplete."
        case "account_unknown":
            "The active local account could not be resolved."
        case "http_429":
            "The vendor is throttling usage refreshes. Last known metrics are kept."
        default:
            if type.hasPrefix("http_") {
                "Vendor returned \(type.replacingOccurrences(of: "http_", with: "HTTP "))."
            } else {
                "Connector reported \(type)."
            }
        }
    }
}
