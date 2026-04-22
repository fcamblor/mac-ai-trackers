import SwiftUI
import AIUsagesTrackersLib

/// Displays active outages for a single vendor as a coloured banner.
/// Rows with a non-nil `href` open the incident URL in the default browser on tap.
struct VendorStatusBanner: View {
    let outages: [Outage]

    var body: some View {
        // Callers only render this view when the vendor has at least one outage
        // (see UsageDetailsView.vendorsNeedingBanner), so `outages.first` is the
        // representative tint source.
        let bannerTint = outages.first.map { Self.tintColor(for: $0.severity) } ?? .gray

        VStack(alignment: .leading, spacing: 6) {
            if let label = vendorLabel {
                Text("\(label) status")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(bannerTint)
                    .textCase(.uppercase)
            }
            ForEach(outages) { outage in
                outageRow(outage)
            }
        }
        .padding(8)
        .background(bannerTint.opacity(0.12), in: RoundedRectangle(cornerRadius: 6))
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .strokeBorder(bannerTint.opacity(0.30), lineWidth: 1)
        )
    }

    /// All outages passed to this banner share the same vendor (grouped by
    /// `UsagesFile.outagesByVendor`), so the first entry is representative.
    private var vendorLabel: String? {
        outages.first.map { $0.vendor.rawValue.capitalized }
    }

    @ViewBuilder
    private func outageRow(_ outage: Outage) -> some View {
        let tint = Self.tintColor(for: outage.severity)
        let isLink = outage.href != nil

        HStack(alignment: .top, spacing: 6) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(tint)
                .font(.system(size: 11))
                .padding(.top, 1)

            VStack(alignment: .leading, spacing: 2) {
                Text(outage.errorMessage)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.primary)
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)

                Text(Self.sinceLabel(for: outage.since))
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }

            Spacer()

            if isLink {
                Image(systemName: "arrow.up.right.square")
                    .font(.system(size: 11))
                    .foregroundStyle(tint)
                    .padding(.top, 1)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture {
            if let url = outage.href {
                NSWorkspace.shared.open(url)
            }
        }
        .onHover { hovering in
            guard isLink else { return }
            if hovering {
                NSCursor.pointingHand.push()
            } else {
                NSCursor.pop()
            }
        }
        .help(isLink ? "Open incident details" : "")
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
