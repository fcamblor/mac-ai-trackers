import SwiftUI
import AppKit
import AIUsagesTrackersLib

struct MenubarHintSettingsView: View {
    let preferences: any AppPreferences

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        if let store = AppDelegate.sharedStore {
            MenubarHintContent(
                preferences: preferences,
                store: store,
                isDark: colorScheme == .dark
            )
        } else {
            ContentUnavailableView(
                "Settings loading",
                systemImage: "hourglass",
                description: Text("Usage data is initializing. Close and reopen Settings.")
            )
        }
    }
}

// MARK: - Row frame preference key

private struct RowFramePreferenceKey: PreferenceKey {
    static let defaultValue: [UUID: CGRect] = [:]
    static func reduce(value: inout [UUID: CGRect], nextValue: () -> [UUID: CGRect]) {
        value.merge(nextValue()) { _, new in new }
    }
}

// MARK: - Content

private struct MenubarHintContent: View {
    let preferences: any AppPreferences
    @Bindable var store: UsageStore
    let isDark: Bool

    private static let segmentListCoordinateSpace = "menubarHint.segmentList"

    @State private var pendingDelete: UUID?

    // Drag state
    @State private var rowFrames: [UUID: CGRect] = [:]
    @State private var draggingID: UUID?
    @State private var dragTranslation: CGSize = .zero
    @State private var dragCursorY: CGFloat = 0
    @State private var dropIndex: Int?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                globalPanel
                Divider()
                segmentsPanel
            }
        }
        .confirmationDialog(
            deleteConfirmationTitle,
            isPresented: deleteConfirmationBinding,
            titleVisibility: .visible
        ) {
            Button("Delete segment", role: .destructive) {
                if let id = pendingDelete {
                    delete(segmentID: id)
                }
                pendingDelete = nil
            }
            Button("Cancel", role: .cancel) {
                pendingDelete = nil
            }
        } message: {
            Text("This segment will no longer appear in the menu bar.")
        }
    }

    // MARK: Global (preview + separator)

    private var globalPanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text("Menu bar preview")
                    .font(.headline)
                Spacer()
                separatorField
            }

            HStack {
                Image(nsImage: MenuBarLabelRenderer.render(
                    segments: store.menuBarSegments,
                    separator: preferences.menuBarSeparator,
                    fallbackText: store.menuBarText,
                    isDarkMenuBar: isDark
                ))
                Spacer()
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(isDark ? Color.black.opacity(0.6) : Color.white)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .stroke(Color.secondary.opacity(0.3), lineWidth: 1)
            )
        }
        .padding(16)
    }

    private var separatorField: some View {
        HStack(spacing: 6) {
            Text("Separator")
                .font(.caption)
                .foregroundStyle(.secondary)
            TextField("", text: Binding(
                get: { preferences.menuBarSeparator },
                set: { preferences.menuBarSeparator = $0 }
            ))
            .textFieldStyle(.roundedBorder)
            .frame(width: 64)
        }
    }

    // MARK: Segments

    @ViewBuilder
    private var segmentsPanel: some View {
        if AppDelegate.sharedPreferences.menuBarSegments.isEmpty {
            emptyState
        } else {
            segmentsList
        }
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Spacer(minLength: 24)
            Text("No segments configured")
                .font(.headline)
            Text("The menu bar will show \"--\" until you add a segment.")
                .font(.caption)
                .foregroundStyle(.secondary)
            Button {
                addSegment()
            } label: {
                Label("Add your first segment", systemImage: "plus")
            }
            .disabled(availableVendors.isEmpty)
            Spacer(minLength: 24)
        }
        .frame(maxWidth: .infinity)
        .padding(16)
    }

    private var segmentsList: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Segments")
                    .font(.headline)
                Text("· drag the handle to reorder")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                Spacer()
                Button {
                    addSegment()
                } label: {
                    Label("Add", systemImage: "plus")
                }
                .disabled(availableVendors.isEmpty)
            }
            .padding(.bottom, 2)

            segmentsListBody
        }
        .padding(.horizontal, 16)
        .padding(.top, 12)
        .padding(.bottom, 16)
    }

    private var segmentsListBody: some View {
        let segments = AppDelegate.sharedPreferences.menuBarSegments
        return ZStack(alignment: .topLeading) {
            VStack(spacing: 4) {
                ForEach(Array(segments.enumerated()), id: \.element.id) { index, segment in
                    rowContainer(segment: segment, index: index, count: segments.count)
                }
            }
            .animation(.spring(response: 0.34, dampingFraction: 0.85), value: draggingID)
            .animation(.spring(response: 0.34, dampingFraction: 0.85), value: dropIndex)

            dropIndicator(segments: segments)
            floatingPreview(segments: segments)
        }
        .coordinateSpace(name: Self.segmentListCoordinateSpace)
        .onPreferenceChange(RowFramePreferenceKey.self) { rowFrames = $0 }
    }

    private func rowContainer(segment: MenuBarSegmentConfig, index: Int, count: Int) -> some View {
        let isDragging = draggingID == segment.id
        return SegmentCardView(
            preferences: preferences,
            store: store,
            isDark: isDark,
            segmentID: segment.id,
            canMoveUp: index > 0,
            canMoveDown: index < count - 1,
            onMoveUp: { move(from: index, to: index - 1) },
            onMoveDown: { move(from: index, to: index + 2) },
            onDuplicate: { duplicate(segmentID: segment.id) },
            onRequestDelete: { pendingDelete = segment.id },
            isBeingDragged: isDragging,
            dragCoordinateSpace: Self.segmentListCoordinateSpace,
            onDragChanged: { value in handleDragChanged(value: value, segmentID: segment.id) },
            onDragEnded: { value in handleDragEnded(value: value, segmentID: segment.id) }
        )
        .background(
            GeometryReader { geo in
                Color.clear.preference(
                    key: RowFramePreferenceKey.self,
                    value: [segment.id: geo.frame(in: .named(Self.segmentListCoordinateSpace))]
                )
            }
        )
        .opacity(isDragging ? 0.0 : 1.0)
        .frame(maxHeight: isDragging ? 0 : nil)
        .clipped()
    }

    // MARK: Drop indicator + floating preview

    @ViewBuilder
    private func dropIndicator(segments: [MenuBarSegmentConfig]) -> some View {
        if let dropIndex, let y = dropIndicatorY(segments: segments, atIndex: dropIndex) {
            Capsule()
                .fill(Color.accentColor)
                .frame(height: 2)
                .padding(.horizontal, 4)
                .offset(y: y - 1)
                .allowsHitTesting(false)
                .transition(.opacity)
        }
    }

    private func dropIndicatorY(segments: [MenuBarSegmentConfig], atIndex index: Int) -> CGFloat? {
        let visible = segments.filter { $0.id != draggingID }
        guard !visible.isEmpty else { return 0 }
        let clamped = max(0, min(index, visible.count))
        if clamped == 0 {
            return rowFrames[visible[0].id]?.minY
        }
        if clamped >= visible.count {
            return rowFrames[visible.last!.id]?.maxY
        }
        // Halfway between previous row's bottom and next row's top
        let prev = rowFrames[visible[clamped - 1].id]?.maxY ?? 0
        let next = rowFrames[visible[clamped].id]?.minY ?? prev
        return (prev + next) / 2
    }

    @ViewBuilder
    private func floatingPreview(segments: [MenuBarSegmentConfig]) -> some View {
        if let id = draggingID,
           let segment = segments.first(where: { $0.id == id }),
           let frame = rowFrames[id] {
            DragPreviewCard(
                preferences: preferences,
                store: store,
                isDark: isDark,
                segment: segment
            )
            .frame(width: max(frame.width, 200))
            .offset(
                x: frame.minX,
                y: dragCursorY - frame.height / 2
            )
            .allowsHitTesting(false)
            .transition(.opacity)
        }
    }

    // MARK: Drag handling

    private func handleDragChanged(value: DragGesture.Value, segmentID: UUID) {
        if draggingID == nil {
            withAnimation(.spring(response: 0.28, dampingFraction: 0.85)) {
                draggingID = segmentID
            }
        }
        dragTranslation = value.translation
        dragCursorY = value.location.y
        let segments = AppDelegate.sharedPreferences.menuBarSegments
        dropIndex = computeDropIndex(at: value.location.y, segments: segments)
    }

    private func handleDragEnded(value: DragGesture.Value, segmentID: UUID) {
        let segments = AppDelegate.sharedPreferences.menuBarSegments
        let finalIndex = computeDropIndex(at: value.location.y, segments: segments)
        performDrop(draggedID: segmentID, toVisibleIndex: finalIndex)
        withAnimation(.spring(response: 0.34, dampingFraction: 0.82)) {
            draggingID = nil
            dropIndex = nil
            dragTranslation = .zero
        }
    }

    private func computeDropIndex(at y: CGFloat, segments: [MenuBarSegmentConfig]) -> Int {
        let visible = segments.filter { $0.id != draggingID }
        for (idx, seg) in visible.enumerated() {
            guard let frame = rowFrames[seg.id] else { continue }
            if y < frame.midY {
                return idx
            }
        }
        return visible.count
    }

    private func performDrop(draggedID: UUID, toVisibleIndex visibleIndex: Int) {
        let prefs = AppDelegate.sharedPreferences
        var segments = prefs.menuBarSegments
        guard let sourceIdx = segments.firstIndex(where: { $0.id == draggedID }) else { return }

        // visibleIndex is in the list with the source removed; translate to an
        // insertion offset for the full list using `move(fromOffsets:toOffset:)`,
        // which expects the destination expressed in pre-removal coordinates.
        let destOffset: Int
        if visibleIndex >= sourceIdx {
            destOffset = visibleIndex + 1
        } else {
            destOffset = visibleIndex
        }

        if destOffset == sourceIdx || destOffset == sourceIdx + 1 {
            return // no-op move
        }

        segments.move(fromOffsets: IndexSet(integer: sourceIdx), toOffset: destOffset)
        prefs.menuBarSegments = segments
    }

    // MARK: Mutations

    private func addSegment() {
        let prefs = AppDelegate.sharedPreferences
        guard let vendor = availableVendors.first else { return }
        let defaultMetricName = firstAvailableMetricName(for: vendor, account: .currentlyActive) ?? ""
        let display: SegmentDisplay = makeDefaultDisplay(
            vendor: vendor,
            account: .currentlyActive,
            metricName: defaultMetricName
        )
        let new = MenuBarSegmentConfig(
            vendor: vendor,
            account: .currentlyActive,
            metricName: defaultMetricName,
            display: display
        )
        prefs.menuBarSegments.append(new)
    }

    private func duplicate(segmentID: UUID) {
        let prefs = AppDelegate.sharedPreferences
        var segments = prefs.menuBarSegments
        guard let idx = segments.firstIndex(where: { $0.id == segmentID }) else { return }
        let source = segments[idx]
        let copy = MenuBarSegmentConfig(
            vendor: source.vendor,
            account: source.account,
            metricName: source.metricName,
            display: source.display,
            showOutageWarning: source.showOutageWarning,
            outageWarningText: source.outageWarningText
        )
        segments.insert(copy, at: idx + 1)
        prefs.menuBarSegments = segments
    }

    private func delete(segmentID: UUID) {
        let prefs = AppDelegate.sharedPreferences
        prefs.menuBarSegments.removeAll { $0.id == segmentID }
    }

    private func move(from source: Int, to destination: Int) {
        let prefs = AppDelegate.sharedPreferences
        var segments = prefs.menuBarSegments
        guard source >= 0, source < segments.count else { return }
        let dest = max(0, min(destination, segments.count))
        segments.move(fromOffsets: IndexSet(integer: source), toOffset: dest)
        prefs.menuBarSegments = segments
    }

    // MARK: Helpers

    private var availableVendors: [Vendor] {
        Array(Set(store.entries.map(\.vendor))).sorted { $0.rawValue < $1.rawValue }
    }

    private func firstAvailableMetricName(
        for vendor: Vendor,
        account: AccountSelection
    ) -> String? {
        let entry = resolveEntry(vendor: vendor, account: account, in: store.entries)
        return entry?.metrics.compactMap(metricName).first
    }

    private func makeDefaultDisplay(
        vendor: Vendor,
        account: AccountSelection,
        metricName: String
    ) -> SegmentDisplay {
        let entry = resolveEntry(vendor: vendor, account: account, in: store.entries)
        let metric = entry?.metrics.first(where: { SegmentEditingHelpers.metricName($0) == metricName })
        switch metric {
        case .some(.payAsYouGo):
            return .payAsYouGo
        case .some(.timeWindow), .some(.unknown), .none:
            return .timeWindow(TimeWindowDisplay(letter: MenuBarMetricLetter.defaultLetter(for: metricName)))
        }
    }

    private func resolveEntry(
        vendor: Vendor,
        account: AccountSelection,
        in entries: [VendorUsageEntry]
    ) -> VendorUsageEntry? {
        let vendorEntries = entries.filter { $0.vendor == vendor }
        switch account {
        case .currentlyActive:
            return vendorEntries.first(where: { $0.isActive })
        case .specific(let email):
            return vendorEntries.first(where: { $0.account == email })
        }
    }

    private func metricName(_ metric: UsageMetric) -> String? {
        SegmentEditingHelpers.metricName(metric)
    }

    private var deleteConfirmationBinding: Binding<Bool> {
        Binding(
            get: { pendingDelete != nil },
            set: { if !$0 { pendingDelete = nil } }
        )
    }

    private var deleteConfirmationTitle: String {
        guard let id = pendingDelete,
              let segment = AppDelegate.sharedPreferences.menuBarSegments.first(where: { $0.id == id }) else {
            return "Delete segment?"
        }
        return "Delete \(segment.metricName) segment?"
    }
}

// MARK: - Drag preview card

private struct DragPreviewCard: View {
    let preferences: any AppPreferences
    @Bindable var store: UsageStore
    let isDark: Bool
    let segment: MenuBarSegmentConfig

    var body: some View {
        let resolution = MenuBarSegmentResolver.resolve(
            config: segment,
            entries: store.entries,
            now: Date()
        )
        HStack(spacing: 10) {
            Image(systemName: "line.3.horizontal")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                if let rendered = resolution.rendered {
                    Image(nsImage: MenuBarLabelRenderer.render(
                        segments: [rendered],
                        separator: preferences.menuBarSeparator,
                        fallbackText: "",
                        isDarkMenuBar: isDark
                    ))
                } else {
                    Text(VendorBrandingResolver.displayName(for: segment.vendor))
                        .fontWeight(.semibold)
                }
                Text("\(VendorBrandingResolver.displayName(for: segment.vendor)) · \(segment.metricName)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(.background)
                .shadow(color: .black.opacity(0.28), radius: 14, x: 0, y: 6)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(Color.accentColor.opacity(0.5), lineWidth: 1)
        )
        .rotationEffect(.degrees(-1.2))
        .scaleEffect(1.02)
    }
}
