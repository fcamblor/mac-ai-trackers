import SwiftUI
import AppKit
import AIUsagesTrackersLib

struct SegmentCardView: View {
    let preferences: any AppPreferences
    @Bindable var store: UsageStore
    let isDark: Bool
    let index: Int
    let canMoveUp: Bool
    let canMoveDown: Bool
    let onMoveUp: () -> Void
    let onMoveDown: () -> Void
    let onRequestDelete: () -> Void

    @State private var isExpanded: Bool = false

    private var segment: MenuBarSegmentConfig? {
        guard preferences.menuBarSegments.indices.contains(index) else { return nil }
        return preferences.menuBarSegments[index]
    }

    var body: some View {
        if let segment {
            DisclosureGroup(isExpanded: $isExpanded) {
                SegmentEditor(
                    preferences: preferences,
                    store: store,
                    index: index
                )
                .padding(.top, 8)
            } label: {
                header(for: segment)
            }
            .padding(.vertical, 4)
        }
    }

    private func header(for segment: MenuBarSegmentConfig) -> some View {
        HStack(spacing: 8) {
            summary(for: segment)
                .frame(maxWidth: .infinity, alignment: .leading)

            HStack(spacing: 4) {
                Button(action: onMoveUp) {
                    Image(systemName: "arrow.up")
                }
                .buttonStyle(.borderless)
                .disabled(!canMoveUp)
                .help("Move up")

                Button(action: onMoveDown) {
                    Image(systemName: "arrow.down")
                }
                .buttonStyle(.borderless)
                .disabled(!canMoveDown)
                .help("Move down")

                Button(action: onRequestDelete) {
                    Image(systemName: "trash")
                        .foregroundStyle(.red)
                }
                .buttonStyle(.borderless)
                .help("Delete segment")
            }
        }
    }

    @ViewBuilder
    private func summary(for segment: MenuBarSegmentConfig) -> some View {
        let resolution = MenuBarSegmentResolver.resolve(
            config: segment,
            entries: store.entries,
            now: Date()
        )
        if let rendered = resolution.rendered {
            HStack(spacing: 6) {
                VendorIconView(vendor: segment.vendor, size: 13)
                Image(nsImage: MenuBarLabelRenderer.render(
                    segments: [rendered],
                    fallbackText: "",
                    isDarkMenuBar: isDark
                ))
                Text(hintText(for: segment))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        } else if let issue = resolution.issue {
            HStack(spacing: 6) {
                VendorIconView(vendor: segment.vendor, size: 13)
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                Text(warningText(for: issue))
                    .foregroundStyle(.orange)
            }
        } else {
            HStack(spacing: 6) {
                VendorIconView(vendor: segment.vendor, size: 13)
                Text(hintText(for: segment))
            }
        }
    }

    private func hintText(for segment: MenuBarSegmentConfig) -> String {
        "\(VendorBranding.displayName(for: segment.vendor)) · \(accountLabel(for: segment)) · \(segment.metricName)"
    }

    private func accountLabel(for segment: MenuBarSegmentConfig) -> String {
        switch segment.account {
        case .currentlyActive:
            if let entry = store.entries.first(where: { $0.vendor == segment.vendor && $0.isActive }) {
                return "\(entry.account.rawValue) (active)"
            }
            return "currently active"
        case .specific(let email):
            return email.rawValue
        }
    }

    private func warningText(for issue: MenuBarSegmentIssue) -> String {
        switch issue {
        case .noActiveAccount(let vendor):
            return "No active \(VendorBranding.displayName(for: vendor)) account"
        case .accountNotFound(_, let email):
            return "Account no longer available: \(email.rawValue)"
        case .metricNotFound(let name):
            return "Metric not found: \(name)"
        case .metricKindMismatch:
            return "Metric kind changed — please reconfigure"
        }
    }
}
