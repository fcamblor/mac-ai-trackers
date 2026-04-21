import SwiftUI
import AIUsagesTrackersLib

/// Displays active outages for a single vendor as a coloured banner.
/// Rows with a non-nil `href` open the incident URL in the default browser on tap.
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
                Text(outage.errorMessage)
                    .font(.system(size: 11, weight: .medium))
                    .lineLimit(3)

                Text(Self.sinceLabel(for: outage.since))
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
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
            if let url = outage.href {
                NSWorkspace.shared.open(url)
            }
        }
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

    /// Short rendering such as "Since Apr 15, 14:53", falling back to the raw ISO
    /// string when the timestamp cannot be parsed (upstream quirks should not break the UI).
    private static func sinceLabel(for iso: ISODate) -> String {
        guard let date = iso.date else { return "Since \(iso.rawValue)" }
        return "Since \(sinceFormatter.string(from: date))"
    }

    private static let sinceFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "MMM d, HH:mm"
        return f
    }()
}
