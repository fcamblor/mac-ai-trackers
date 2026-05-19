import SwiftUI
import AppKit
import AIUsagesTrackersLib

struct SegmentCardView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    let preferences: any AppPreferences
    @Bindable var store: UsageStore
    let isDark: Bool
    let segmentID: UUID
    let canMoveUp: Bool
    let canMoveDown: Bool
    let onMoveUp: () -> Void
    let onMoveDown: () -> Void
    let onDuplicate: () -> Void
    let onRequestDelete: () -> Void
    let isBeingDragged: Bool
    let dragCoordinateSpace: String
    let onDragChanged: (DragGesture.Value) -> Void
    let onDragEnded: (DragGesture.Value) -> Void

    @State private var isExpanded: Bool = false
    @State private var isHovering: Bool = false

    private var segment: MenuBarSegmentConfig? {
        preferences.menuBarSegments.first(where: { $0.id == segmentID })
    }

    var body: some View {
        if let segment {
            VStack(alignment: .leading, spacing: 0) {
                header(for: segment)
                if isExpanded {
                    SegmentEditor(
                        preferences: preferences,
                        store: store,
                        segmentID: segmentID,
                        isDark: isDark
                    )
                    .padding(.top, 6)
                    .padding(.leading, 30)
                    .padding(.trailing, 4)
                    .padding(.bottom, 10)
                    .transition(expandedEditorTransition)
                }
            }
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(rowBackground)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(Color.secondary.opacity(isExpanded ? 0.22 : 0.0), lineWidth: 1)
            )
            .onHover { isHovering = $0 }
            .contextMenu {
                Button("Duplicate", systemImage: "plus.square.on.square", action: onDuplicate)
                Divider()
                Button("Move up", systemImage: "arrow.up", action: onMoveUp)
                    .disabled(!canMoveUp)
                Button("Move down", systemImage: "arrow.down", action: onMoveDown)
                    .disabled(!canMoveDown)
                Divider()
                Button("Delete", systemImage: "trash", role: .destructive, action: onRequestDelete)
            }
        }
    }

    private var rowBackground: Color {
        if isExpanded {
            return Color.secondary.opacity(0.07)
        }
        return isHovering ? Color.secondary.opacity(0.05) : Color.clear
    }

    // MARK: Header

    private func header(for segment: MenuBarSegmentConfig) -> some View {
        HStack(spacing: 8) {
            dragHandle
            disclosureArea(for: segment)
            actions
        }
        .padding(.horizontal, 8)
    }

    private var dragHandle: some View {
        Image(systemName: "line.3.horizontal")
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(isHovering ? Color.secondary : Color.secondary.opacity(0.55))
            .frame(width: 18, height: 28)
            .contentShape(Rectangle())
            .help("Drag to reorder")
            .onHover { hovering in
                if hovering {
                    NSCursor.openHand.push()
                } else {
                    NSCursor.pop()
                }
            }
            .gesture(
                DragGesture(minimumDistance: 4, coordinateSpace: .named(dragCoordinateSpace))
                    .onChanged(onDragChanged)
                    .onEnded(onDragEnded)
            )
    }

    private func disclosureArea(for segment: MenuBarSegmentConfig) -> some View {
        HStack(spacing: 8) {
            disclosureChevron
            summary(for: segment)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .onTapGesture {
            withAnimation(.easeOut(duration: 0.18)) { isExpanded.toggle() }
        }
    }

    private var expandedEditorTransition: AnyTransition {
        guard !reduceMotion else { return .identity }
        return .asymmetric(
            insertion: .opacity.combined(with: .scale(scale: 0.985, anchor: .top)),
            removal: .opacity
        )
    }

    private var disclosureChevron: some View {
        Image(systemName: "chevron.right")
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(.secondary)
            .rotationEffect(.degrees(isExpanded ? 90 : 0))
            .frame(width: 12)
    }

    @ViewBuilder
    private func summary(for segment: MenuBarSegmentConfig) -> some View {
        let resolution = MenuBarSegmentResolver.resolve(
            config: segment,
            entries: store.entries,
            now: Date()
        )
        VStack(alignment: .leading, spacing: 2) {
            primaryRow(for: segment, resolution: resolution)
            secondaryLine(for: segment, resolution: resolution)
        }
    }

    @ViewBuilder
    private func primaryRow(
        for segment: MenuBarSegmentConfig,
        resolution: ResolvedMenuBarSegment
    ) -> some View {
        if let rendered = resolution.rendered {
            Image(nsImage: MenuBarLabelRenderer.render(
                segments: [rendered],
                separator: preferences.menuBarSeparator,
                fallbackText: "",
                isDarkMenuBar: isDark
            ))
        } else {
            HStack(spacing: 6) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .font(.caption)
                Text(warningText(for: resolution.issue))
                    .foregroundStyle(.orange)
                    .font(.callout)
            }
        }
    }

    private func secondaryLine(
        for segment: MenuBarSegmentConfig,
        resolution: ResolvedMenuBarSegment
    ) -> some View {
        HStack(spacing: 6) {
            Text(VendorBrandingResolver.displayName(for: segment.vendor))
                .fontWeight(.medium)
            Text("·").foregroundStyle(.tertiary)
            Text(accountLabel(for: segment))
                .lineLimit(1)
                .truncationMode(.middle)
            Text("·").foregroundStyle(.tertiary)
            Text(segment.metricName)
                .lineLimit(1)
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }

    private var actions: some View {
        HStack(spacing: 2) {
            Button(action: onDuplicate) {
                Image(systemName: "plus.square.on.square")
            }
            .buttonStyle(.borderless)
            .help("Duplicate segment")

            Button(action: onRequestDelete) {
                Image(systemName: "trash")
                    .foregroundStyle(.red)
            }
            .buttonStyle(.borderless)
            .help("Delete segment")
        }
        .opacity(isHovering || isExpanded ? 1.0 : 0.45)
    }

    // MARK: Helpers

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

    private func warningText(for issue: MenuBarSegmentIssue?) -> String {
        guard let issue else { return "Configuration issue" }
        switch issue {
        case .noActiveAccount(let vendor):
            return "No active \(VendorBrandingResolver.displayName(for: vendor)) account"
        case .accountNotFound(_, let email):
            return "Account no longer available: \(email.rawValue)"
        case .metricNotFound(let name):
            return "Metric not found: \(name)"
        case .metricKindMismatch:
            return "Metric kind changed — please reconfigure"
        }
    }
}
