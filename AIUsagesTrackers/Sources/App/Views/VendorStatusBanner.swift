import SwiftUI
import AIUsagesTrackersLib

/// Displays active outages for a single vendor as a coloured banner.
/// Tapped incidents open the incident URL in the default browser when present.
struct VendorStatusBanner: View {
    let outages: [Outage]

    var body: some View {
        VStack(spacing: 4) {
            ForEach(outages) { outage in
                outageRow(outage)
            }
        }
    }

    @ViewBuilder
    private func outageRow(_ outage: Outage) -> some View {
        let tint = Self.tintColor(for: outage.severity)

        HStack(alignment: .top, spacing: 6) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(tint)
                .font(.system(size: 11))
                .padding(.top, 1)

            VStack(alignment: .leading, spacing: 2) {
                Text(outage.title)
                    .font(.system(size: 11, weight: .medium))
                    .lineLimit(2)

                if !outage.affectedComponents.isEmpty {
                    Text(outage.affectedComponents.joined(separator: ", "))
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }

            Spacer()
        }
        .padding(8)
        .background(tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 6))
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .strokeBorder(tint.opacity(0.30), lineWidth: 1)
        )
        .contentShape(Rectangle())
        .onTapGesture {
            if let urlString = outage.url, let url = URL(string: urlString) {
                NSWorkspace.shared.open(url)
            }
        }
        .buttonStyle(.plain)
        .focusable(false)
    }

    private static func tintColor(for severity: OutageSeverity) -> Color {
        switch severity {
        case .critical, .major: return .red
        case .minor:            return .orange
        case .maintenance:      return .blue
        default:                return .gray
        }
    }
}
