import SwiftUI
import AIUsagesTrackersLib

// MARK: - Popover metrics section

/// Per-assistant picker for the rows shown in the popover cards. Each row is a
/// chip that reads as its own state — filled when shown, dashed and dimmed when
/// hidden — so the result is visible without decoding checkbox columns.
/// Lists only rows the current accounts actually display.
struct PopoverMetricsSection: View {
    private var prefs: UserDefaultsAppPreferences { AppDelegate.sharedPreferences }

    var body: some View {
        let visibility = prefs.popoverMetricVisibility
        let catalog = PopoverRowCatalog.build(
            entries: AppDelegate.sharedStore?.entries ?? [],
            visibility: visibility
        )
        Text("Click a metric to hide it from the popover cards of that assistant. Hidden metrics keep working in menu bar chips and charts.")
            .font(.caption)
            .foregroundStyle(.secondary)
        if catalog.isEmpty {
            Text("No metrics reported yet.")
                .foregroundStyle(.secondary)
        }
        ForEach(catalog, id: \.family) { family in
            AssistantMetricsRow(
                family: family,
                label: familyLabel(family),
                visibility: visibility,
                onChange: { prefs.popoverMetricVisibility = $0 }
            )
        }
    }

    private func familyLabel(_ family: PopoverRowCatalogEntry) -> String {
        // The Claude family spans TUI + Desktop; name it after the brand, not one source.
        family.family == Vendor.claudeTUI.accountFamily
            ? "Claude"
            : VendorBrandingResolver.displayName(for: family.representativeVendor)
    }
}

struct AssistantMetricsRow: View {
    let family: PopoverRowCatalogEntry
    let label: String
    let visibility: PopoverMetricVisibility
    let onChange: (PopoverMetricVisibility) -> Void

    private var hiddenCount: Int {
        family.rowNames.filter { visibility.isHidden($0, family: family.family) }.count
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                VendorIconView(vendor: family.representativeVendor, size: 13)
                Text(label)
                    .font(.system(size: 12, weight: .semibold))
                Spacer()
                Text(summary)
                    .font(.system(size: 11).monospacedDigit())
                    .foregroundStyle(.secondary)
                if hiddenCount > 0 {
                    Button("Show all") { set(family.rowNames, hidden: false) }
                        .buttonStyle(.link)
                        .font(.system(size: 11))
                }
            }
            ForEach(Array(family.groups.enumerated()), id: \.offset) { _, group in
                groupView(group)
            }
        }
        .padding(.vertical, 4)
    }

    private var summary: String {
        let shown = family.rowNames.count - hiddenCount
        return hiddenCount == 0 ? "all \(shown) shown" : "\(shown) of \(family.rowNames.count) shown"
    }

    @ViewBuilder
    private func groupView(_ group: PopoverRowGroup) -> some View {
        if let title = group.title {
            let names = group.rows.map(\.name)
            let allHidden = names.allSatisfy { visibility.isHidden($0, family: family.family) }
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(title)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)
                    Button(allHidden ? "show group" : "hide group") { set(names, hidden: !allHidden) }
                        .buttonStyle(.link)
                        .font(.system(size: 10))
                }
                chips(group.rows)
            }
        } else {
            chips(group.rows)
        }
    }

    private func chips(_ rows: [PopoverRowGroup.Row]) -> some View {
        ChipFlowLayout(spacing: 6) {
            ForEach(rows, id: \.name) { row in
                MetricVisibilityChip(
                    label: row.label,
                    isShown: !visibility.isHidden(row.name, family: family.family),
                    toggle: { set([row.name], hidden: !visibility.isHidden(row.name, family: family.family)) }
                )
            }
        }
    }

    private func set(_ names: [String], hidden: Bool) {
        var updated = visibility
        for name in names {
            updated.setHidden(hidden, rowName: name, family: family.family)
        }
        onChange(updated)
    }
}

/// A toggleable capsule. Shown: tinted fill + eye. Hidden: dashed outline,
/// dimmed and struck through, so the "off" state survives a quick glance.
private struct MetricVisibilityChip: View {
    let label: String
    let isShown: Bool
    let toggle: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: toggle) {
            HStack(spacing: 4) {
                Image(systemName: isShown ? "eye" : "eye.slash")
                    .font(.system(size: 9, weight: .semibold))
                Text(label)
                    .font(.system(size: 11, weight: .medium))
                    .strikethrough(!isShown, color: .secondary)
                    .lineLimit(1)
            }
            .foregroundStyle(isShown ? Color.primary : Color.secondary)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(
                Capsule().fill(isShown ? Color.accentColor.opacity(isHovering ? 0.26 : 0.16) : Color.primary.opacity(isHovering ? 0.06 : 0))
            )
            .overlay(
                Capsule().strokeBorder(
                    isShown ? Color.accentColor.opacity(0.35) : Color.secondary.opacity(0.5),
                    style: StrokeStyle(lineWidth: 1, dash: isShown ? [] : [3, 2])
                )
            )
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .help(isShown ? "Shown in the popover — click to hide" : "Hidden from the popover — click to show")
        .accessibilityLabel(label)
        .accessibilityValue(isShown ? "shown" : "hidden")
    }
}

/// Wraps chips onto as many lines as the available width needs, left-aligned.
struct ChipFlowLayout: Layout {
    var spacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(subviews: subviews, maxWidth: proposal.width ?? .infinity)
        let width = rows.map(\.width).max() ?? 0
        let height = rows.map(\.height).reduce(0, +) + spacing * CGFloat(max(rows.count - 1, 0))
        return CGSize(width: proposal.width ?? width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in arrange(subviews: subviews, maxWidth: bounds.width) {
            var x = bounds.minX
            for index in row.indices {
                let size = subviews[index].sizeThatFits(.unspecified)
                subviews[index].place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
            y += row.height + spacing
        }
    }

    private struct Row {
        var indices: [Int] = []
        var width: CGFloat = 0
        var height: CGFloat = 0
    }

    private func arrange(subviews: Subviews, maxWidth: CGFloat) -> [Row] {
        var rows: [Row] = []
        var current = Row()
        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(.unspecified)
            let needed = current.indices.isEmpty ? size.width : current.width + spacing + size.width
            if needed > maxWidth, !current.indices.isEmpty {
                rows.append(current)
                current = Row()
            }
            current.width = current.indices.isEmpty ? size.width : current.width + spacing + size.width
            current.height = max(current.height, size.height)
            current.indices.append(index)
        }
        if !current.indices.isEmpty { rows.append(current) }
        return rows
    }
}
