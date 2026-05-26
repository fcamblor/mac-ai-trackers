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

    private static let chipListCoordinateSpace = "menubarHint.chipList"

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
                chipsPanel
            }
        }
        .confirmationDialog(
            deleteConfirmationTitle,
            isPresented: deleteConfirmationBinding,
            titleVisibility: .visible
        ) {
            Button("Delete chip", role: .destructive) {
                if let id = pendingDelete {
                    delete(chipID: id)
                }
                pendingDelete = nil
            }
            Button("Cancel", role: .cancel) {
                pendingDelete = nil
            }
        } message: {
            Text("This chip will no longer appear in the menu bar.")
        }
    }

    // MARK: Global (preview + appearance)

    private var globalPanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text("Menu bar preview")
                    .font(.headline)
                Spacer()
                backgroundPicker
            }

            HStack {
                Image(nsImage: MenuBarLabelRenderer.render(
                    chips: store.menuBarChips,
                    background: preferences.menuBarChipBackground,
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

            #if DEBUG
            devPacingCycleToggle
            #endif
        }
        .padding(16)
    }

    private var backgroundPicker: some View {
        HStack(spacing: 6) {
            Text("Chip background")
                .font(.caption)
                .foregroundStyle(.secondary)
            Picker("", selection: Binding(
                get: { preferences.menuBarChipBackground },
                set: { preferences.menuBarChipBackground = $0 }
            )) {
                Text("Paper").tag(ChipBackground.paper)
                Text("Slate").tag(ChipBackground.slate)
                Text("System").tag(ChipBackground.system)
            }
            .labelsHidden()
            .pickerStyle(.segmented)
            .frame(width: 220)
        }
    }

    #if DEBUG
    private var devPacingCycleToggle: some View {
        Toggle(isOn: Binding(
            get: { preferences.menuBarPacingColorCycleEnabled },
            set: { preferences.menuBarPacingColorCycleEnabled = $0 }
        )) {
            HStack(spacing: 6) {
                Image(systemName: "paintpalette")
                    .foregroundStyle(.tertiary)
                Text("Cycle pacing colors (dev)")
                    .font(.caption)
            }
        }
        .toggleStyle(.checkbox)
        .help("Cycles every visible chip segment through ConsumptionTier.allCases at 1 Hz so the chosen background can be QA'd against each tier colour.")
    }
    #endif

    // MARK: Chips list

    @ViewBuilder
    private var chipsPanel: some View {
        if AppDelegate.sharedPreferences.menuBarChips.isEmpty {
            emptyState
        } else {
            chipsList
        }
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Spacer(minLength: 24)
            Text("No chips configured")
                .font(.headline)
            Text("The menu bar will show \"--\" until you add a chip.")
                .font(.caption)
                .foregroundStyle(.secondary)
            Button {
                addChip()
            } label: {
                Label("Add your first chip", systemImage: "plus")
            }
            .disabled(availableVendors.isEmpty)
            Spacer(minLength: 24)
        }
        .frame(maxWidth: .infinity)
        .padding(16)
    }

    private var chipsList: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Chips")
                    .font(.headline)
                Text("· drag the handle to reorder")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                Spacer()
                Button {
                    addChip()
                } label: {
                    Label("Add", systemImage: "plus")
                }
                .disabled(availableVendors.isEmpty)
            }
            .padding(.bottom, 2)

            chipsListBody
        }
        .padding(.horizontal, 16)
        .padding(.top, 12)
        .padding(.bottom, 16)
    }

    private var chipsListBody: some View {
        let chips = AppDelegate.sharedPreferences.menuBarChips
        return ZStack(alignment: .topLeading) {
            VStack(spacing: 4) {
                ForEach(Array(chips.enumerated()), id: \.element.id) { index, chip in
                    rowContainer(chip: chip, index: index, count: chips.count)
                }
            }
            .animation(.spring(response: 0.34, dampingFraction: 0.85), value: draggingID)
            .animation(.spring(response: 0.34, dampingFraction: 0.85), value: dropIndex)

            dropIndicator(chips: chips)
            floatingPreview(chips: chips)
        }
        .coordinateSpace(name: Self.chipListCoordinateSpace)
        .onPreferenceChange(RowFramePreferenceKey.self) { rowFrames = $0 }
    }

    private func rowContainer(chip: MenuBarChipConfig, index: Int, count: Int) -> some View {
        let isDragging = draggingID == chip.id
        return ChipCardView(
            preferences: preferences,
            store: store,
            isDark: isDark,
            chip: chip,
            canMoveUp: index > 0,
            canMoveDown: index < count - 1,
            onMoveUp: { move(from: index, to: index - 1) },
            onMoveDown: { move(from: index, to: index + 1) },
            onDuplicate: { duplicate(chipID: chip.id) },
            onRequestDelete: { pendingDelete = chip.id },
            isBeingDragged: isDragging,
            dragCoordinateSpace: Self.chipListCoordinateSpace,
            onDragChanged: { value in handleDragChanged(value: value, chipID: chip.id) },
            onDragEnded: { value in handleDragEnded(value: value, chipID: chip.id) }
        )
        .background(
            GeometryReader { geo in
                Color.clear.preference(
                    key: RowFramePreferenceKey.self,
                    value: [chip.id: geo.frame(in: .named(Self.chipListCoordinateSpace))]
                )
            }
        )
        .opacity(isDragging ? 0.0 : 1.0)
        .frame(maxHeight: isDragging ? 0 : nil)
        .clipped()
    }

    // MARK: Drop indicator + floating preview

    @ViewBuilder
    private func dropIndicator(chips: [MenuBarChipConfig]) -> some View {
        if let dropIndex, let y = dropIndicatorY(chips: chips, atIndex: dropIndex) {
            Capsule()
                .fill(Color.accentColor)
                .frame(height: 2)
                .padding(.horizontal, 4)
                .offset(y: y - 1)
                .allowsHitTesting(false)
                .transition(.opacity)
        }
    }

    private func dropIndicatorY(chips: [MenuBarChipConfig], atIndex index: Int) -> CGFloat? {
        let visible = chips.filter { $0.id != draggingID }
        guard let first = visible.first, let last = visible.last else { return 0 }
        let clamped = max(0, min(index, visible.count))
        if clamped == 0 {
            return rowFrames[first.id]?.minY
        }
        if clamped >= visible.count {
            return rowFrames[last.id]?.maxY
        }
        let prev = rowFrames[visible[clamped - 1].id]?.maxY ?? 0
        let next = rowFrames[visible[clamped].id]?.minY ?? prev
        return (prev + next) / 2
    }

    @ViewBuilder
    private func floatingPreview(chips: [MenuBarChipConfig]) -> some View {
        if let id = draggingID,
           let chip = chips.first(where: { $0.id == id }),
           let frame = rowFrames[id] {
            DragPreviewCard(
                preferences: preferences,
                store: store,
                isDark: isDark,
                chip: chip
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

    private func handleDragChanged(value: DragGesture.Value, chipID: UUID) {
        if draggingID == nil {
            withAnimation(.spring(response: 0.28, dampingFraction: 0.85)) {
                draggingID = chipID
            }
        }
        dragTranslation = value.translation
        dragCursorY = value.location.y
        let chips = AppDelegate.sharedPreferences.menuBarChips
        dropIndex = computeDropIndex(at: value.location.y, chips: chips)
    }

    private func handleDragEnded(value: DragGesture.Value, chipID: UUID) {
        let chips = AppDelegate.sharedPreferences.menuBarChips
        let finalIndex = computeDropIndex(at: value.location.y, chips: chips)
        performDrop(draggedID: chipID, toVisibleIndex: finalIndex)
        withAnimation(.spring(response: 0.34, dampingFraction: 0.82)) {
            draggingID = nil
            dropIndex = nil
            dragTranslation = .zero
        }
    }

    private func computeDropIndex(at y: CGFloat, chips: [MenuBarChipConfig]) -> Int {
        let visible = chips.filter { $0.id != draggingID }
        for (idx, c) in visible.enumerated() {
            guard let frame = rowFrames[c.id] else { continue }
            if y < frame.midY {
                return idx
            }
        }
        return visible.count
    }

    private func performDrop(draggedID: UUID, toVisibleIndex visibleIndex: Int) {
        let prefs = AppDelegate.sharedPreferences
        var chips = prefs.menuBarChips
        guard let sourceIdx = chips.firstIndex(where: { $0.id == draggedID }) else { return }

        let destOffset: Int
        if visibleIndex >= sourceIdx {
            destOffset = visibleIndex + 1
        } else {
            destOffset = visibleIndex
        }
        if destOffset == sourceIdx || destOffset == sourceIdx + 1 {
            return
        }
        chips.move(fromOffsets: IndexSet(integer: sourceIdx), toOffset: destOffset)
        prefs.menuBarChips = chips
    }

    // MARK: Mutations

    private func addChip() {
        let prefs = AppDelegate.sharedPreferences
        guard let vendor = availableVendors.first else { return }
        let metricName = firstAvailableMetricName(for: vendor, account: .currentlyActive) ?? ""
        let display = makeDefaultDisplay(
            vendor: vendor,
            account: .currentlyActive,
            metricName: metricName
        )
        let newChip = MenuBarChipConfig(
            vendor: vendor,
            segments: [
                MenuBarChipSegmentConfig(
                    account: .currentlyActive,
                    metricName: metricName,
                    display: display
                )
            ]
        )
        prefs.menuBarChips.append(newChip)
    }

    private func duplicate(chipID: UUID) {
        let prefs = AppDelegate.sharedPreferences
        var chips = prefs.menuBarChips
        guard let idx = chips.firstIndex(where: { $0.id == chipID }) else { return }
        let source = chips[idx]
        let copy = MenuBarChipConfig(
            vendor: source.vendor,
            showVendorIcon: source.showVendorIcon,
            showOutageWarning: source.showOutageWarning,
            outageWarningText: source.outageWarningText,
            segments: source.segments.map {
                MenuBarChipSegmentConfig(
                    account: $0.account,
                    metricName: $0.metricName,
                    display: $0.display
                )
            }
        )
        chips.insert(copy, at: idx + 1)
        prefs.menuBarChips = chips
    }

    private func delete(chipID: UUID) {
        let prefs = AppDelegate.sharedPreferences
        prefs.menuBarChips.removeAll { $0.id == chipID }
    }

    private func move(from source: Int, to destination: Int) {
        let prefs = AppDelegate.sharedPreferences
        var chips = prefs.menuBarChips
        guard source >= 0, source < chips.count else { return }
        let dest = max(0, min(destination, chips.count - 1))
        guard dest != source else { return }
        let element = chips.remove(at: source)
        chips.insert(element, at: dest)
        prefs.menuBarChips = chips
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
              let chip = AppDelegate.sharedPreferences.menuBarChips.first(where: { $0.id == id }) else {
            return "Delete chip?"
        }
        return "Delete \(VendorBrandingResolver.displayName(for: chip.vendor)) chip?"
    }
}

// MARK: - Drag preview card

private struct DragPreviewCard: View {
    let preferences: any AppPreferences
    @Bindable var store: UsageStore
    let isDark: Bool
    let chip: MenuBarChipConfig

    var body: some View {
        let resolution = MenuBarChipResolver.resolve(
            chip: chip,
            entries: store.entries,
            outagesByVendor: store.outagesByVendor,
            now: Date()
        )
        let renderedSegments = resolution.segments.compactMap(\.rendered)
        return HStack(spacing: 10) {
            Image(systemName: "line.3.horizontal")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                if !renderedSegments.isEmpty {
                    let preview = RenderedChip(
                        vendor: chip.vendor,
                        showVendorIcon: chip.showVendorIcon,
                        outageWarningText: resolution.outageWarningText,
                        segments: renderedSegments
                    )
                    Image(nsImage: MenuBarLabelRenderer.render(
                        chips: [preview],
                        background: preferences.menuBarChipBackground,
                        fallbackText: "",
                        isDarkMenuBar: isDark
                    ))
                } else {
                    Text(VendorBrandingResolver.displayName(for: chip.vendor))
                        .fontWeight(.semibold)
                }
                Text("\(VendorBrandingResolver.displayName(for: chip.vendor)) · \(chip.segments.count) segment(s)")
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
