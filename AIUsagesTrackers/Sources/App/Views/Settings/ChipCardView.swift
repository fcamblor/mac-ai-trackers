import SwiftUI
import AppKit
import AIUsagesTrackersLib

private struct SegmentRowFramePreferenceKey: PreferenceKey {
    static let defaultValue: [UUID: CGRect] = [:]
    static func reduce(value: inout [UUID: CGRect], nextValue: () -> [UUID: CGRect]) {
        value.merge(nextValue()) { _, new in new }
    }
}

/// Card view for a single menu-bar chip. Shows the chip-level chrome (vendor,
/// icon toggle, outage warning) and a nested list of editable sub-segments.
/// The chip itself is reorderable through the drag handle (drag & drop is
/// handled by the parent `MenubarHintSettingsView`); sub-segments inside the
/// chip also support drag-and-drop reordering, scoped to this card via its
/// own coordinate space.
struct ChipCardView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    let preferences: any AppPreferences
    @Bindable var store: UsageStore
    let isDark: Bool
    /// The chip to render. Passed as a value (not looked up by id from
    /// `preferences`) so SwiftUI redraws this view whenever the parent
    /// re-reads the chip list — observation of an `any AppPreferences`
    /// existential is not tracked by SwiftUI, hence the explicit value.
    let chip: MenuBarChipConfig
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
    @State private var expandedSegmentID: UUID?

    // Segment drag state — scoped to this chip card.
    @State private var segmentRowFrames: [UUID: CGRect] = [:]
    @State private var draggingSegmentID: UUID?
    @State private var segmentDragCursorY: CGFloat = 0
    @State private var segmentDropIndex: Int?

    private var segmentListCoordinateSpace: String {
        "chipCard.segments.\(chip.id.uuidString)"
    }

    private var chipID: UUID { chip.id }

    private var chipBinding: Binding<MenuBarChipConfig>? {
        SettingsConfigurationBindings.menuBarChip(preferences: preferences, chipID: chipID)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header(for: chip)
            if isExpanded, let chipBinding {
                chipBody(chip: chip, binding: chipBinding)
                    .padding(.top, 6)
                    .padding(.horizontal, 30)
                    .padding(.bottom, 12)
                    .transition(expandedTransition)
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

    private var rowBackground: Color {
        if isExpanded { return Color.secondary.opacity(0.07) }
        return isHovering ? Color.secondary.opacity(0.05) : Color.clear
    }

    // MARK: Header

    private func header(for chip: MenuBarChipConfig) -> some View {
        HStack(spacing: 8) {
            dragHandle
            disclosureArea(for: chip)
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
                if hovering { NSCursor.openHand.push() } else { NSCursor.pop() }
            }
            .gesture(
                DragGesture(minimumDistance: 4, coordinateSpace: .named(dragCoordinateSpace))
                    .onChanged(onDragChanged)
                    .onEnded(onDragEnded)
            )
    }

    private func disclosureArea(for chip: MenuBarChipConfig) -> some View {
        HStack(spacing: 8) {
            disclosureChevron
            summary(for: chip)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .onTapGesture {
            withAnimation(.easeOut(duration: 0.18)) { isExpanded.toggle() }
        }
    }

    private var expandedTransition: AnyTransition {
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
    private func summary(for chip: MenuBarChipConfig) -> some View {
        let resolution = MenuBarChipResolver.resolve(
            chip: chip,
            entries: store.entries,
            outagesByVendor: store.outagesByVendor,
            now: Date()
        )
        let renderedSegments = resolution.segments.compactMap(\.rendered)
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
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                        .font(.caption)
                    Text("No renderable segment")
                        .foregroundStyle(.orange)
                        .font(.callout)
                }
            }
            secondaryLine(for: chip)
        }
    }

    private func secondaryLine(for chip: MenuBarChipConfig) -> some View {
        let segmentSummary = chip.segments.count == 1 ? "1 segment" : "\(chip.segments.count) segments"
        return HStack(spacing: 6) {
            Text(VendorBrandingResolver.displayName(for: chip.vendor))
                .fontWeight(.medium)
            Text("·").foregroundStyle(.tertiary)
            Text(segmentSummary)
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
            .help("Duplicate chip")

            Button(action: onRequestDelete) {
                Image(systemName: "trash")
                    .foregroundStyle(.red)
            }
            .buttonStyle(.borderless)
            .help("Delete chip")
        }
        .opacity(isHovering || isExpanded ? 1.0 : 0.45)
    }

    // MARK: Chip body (chip-level chrome + sub-segments list)

    private func chipBody(chip: MenuBarChipConfig, binding: Binding<MenuBarChipConfig>) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            chipChromeRow(chip: chip, binding: binding)
            Divider()
            segmentsSection(chip: chip, binding: binding)
        }
    }

    private func chipChromeRow(chip: MenuBarChipConfig, binding: Binding<MenuBarChipConfig>) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            chromeSectionTitle("Chip header")

            // Vendor picker — the chip scopes all its segments to one vendor,
            // so the picker lives at the chip level (the SegmentEditor hides
            // its own vendor row to avoid the redundancy).
            HStack(spacing: 10) {
                Text("Vendor")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(width: 56, alignment: .leading)
                Picker("", selection: Binding(
                    // Normalise to the family-canonical vendor so a chip saved
                    // against claude-desktop still matches the single "Claude"
                    // option.
                    get: { chip.vendor.familyCanonicalVendor },
                    set: { newVendor in
                        var c = binding.wrappedValue
                        c.vendor = newVendor
                        // Reset segments' account to .currentlyActive so the
                        // chip never points at an account that belongs to a
                        // different vendor. Metric names are preserved; the
                        // resolver will report `metricNotFound` if needed and
                        // the user can fix it from the segment editor.
                        c.segments = c.segments.map { seg in
                            var s = seg
                            s.account = .currentlyActive
                            return s
                        }
                        binding.wrappedValue = c
                    }
                )) {
                    ForEach(availableVendors, id: \.rawValue) { v in
                        Text(VendorBrandingResolver.familyDisplayName(for: v)).tag(v)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .frame(maxWidth: 200, alignment: .leading)
                Spacer(minLength: 0)
            }

            // Chip-strip toggles — same visual language as the chip-strip in
            // SegmentEditor so the two surfaces feel uniform.
            HStack(alignment: .top, spacing: 6) {
                chromeChip(
                    caption: "Icon",
                    isOn: chip.showVendorIcon,
                    toggle: { binding.wrappedValue.showVendorIcon.toggle() }
                ) {
                    VendorIconView(vendor: chip.vendor, size: 14)
                }

                chromeChip(
                    caption: "Outage",
                    isOn: chip.showOutageWarning,
                    toggle: { binding.wrappedValue.showOutageWarning.toggle() }
                ) {
                    Text(chip.outageWarningText.isEmpty ? "⚠️" : chip.outageWarningText)
                        .font(.system(size: 13))
                }

                Spacer(minLength: 0)
            }

            // Sub-options panel — mirrors `SegmentEditor.subOptionsPanel`
            // so the editing surface for an active toggle lives in the same
            // place at both the chip and the chip-segment level.
            if chip.showOutageWarning {
                VStack(alignment: .leading, spacing: 8) {
                    subOptionRow(label: "Outage text") {
                        TextField("", text: binding.outageWarningText)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 64)
                    }
                }
                .padding(10)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(Color.secondary.opacity(0.07))
                )
            }
        }
    }

    /// Mirrors `SegmentEditor.subOptionRow(label:_:)` so the chip-level
    /// sub-options panel uses the exact same label layout as the per-segment
    /// one.
    private func subOptionRow<Control: View>(
        label: String,
        @ViewBuilder _ control: () -> Control
    ) -> some View {
        HStack(spacing: 10) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 100, alignment: .leading)
            control()
            Spacer(minLength: 0)
        }
    }

    /// Mirrors `SegmentEditor.chip(...)` — keeping the visual language
    /// consistent across the chip-level chrome and the per-segment toggles.
    private func chromeChip<Symbol: View>(
        caption: String,
        isOn: Bool,
        toggle: @escaping () -> Void,
        @ViewBuilder symbol: () -> Symbol
    ) -> some View {
        Button(action: {
            withAnimation(.easeOut(duration: 0.14)) { toggle() }
        }) {
            VStack(spacing: 4) {
                ZStack {
                    RoundedRectangle(cornerRadius: 6)
                        .fill(isOn ? Color.accentColor.opacity(0.16) : Color.clear)
                    RoundedRectangle(cornerRadius: 6)
                        .strokeBorder(
                            isOn ? Color.accentColor.opacity(0.85) : Color.secondary.opacity(0.45),
                            style: StrokeStyle(
                                lineWidth: 1,
                                dash: isOn ? [] : [3, 2]
                            )
                        )
                    symbol()
                        .opacity(isOn ? 1.0 : 0.4)
                }
                .frame(width: 48, height: 32)
                .contentShape(RoundedRectangle(cornerRadius: 6))

                Text(caption)
                    .font(.system(size: 9, weight: isOn ? .semibold : .regular))
                    .tracking(0.4)
                    .textCase(.uppercase)
                    .foregroundStyle(isOn ? Color.primary : Color.secondary)
            }
        }
        .buttonStyle(.plain)
        .help(isOn ? "\(caption) shown — click to hide" : "\(caption) hidden — click to show")
    }

    private var availableVendors: [Vendor] {
        // Collapse claude + claude-desktop into the single "Claude" family entry.
        Array(Set(store.entries.map(\.vendor.familyCanonicalVendor))).sorted { $0.rawValue < $1.rawValue }
    }

    private func chromeSectionTitle(_ text: String) -> some View {
        Text(text)
            .font(.caption2)
            .fontWeight(.semibold)
            .tracking(0.8)
            .textCase(.uppercase)
            .foregroundStyle(.secondary)
    }

    @ViewBuilder
    private func segmentsSection(chip: MenuBarChipConfig, binding: Binding<MenuBarChipConfig>) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                chromeSectionTitle("Segments")
                if chip.segments.count > 1 {
                    Text("· drag the handle to reorder")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                Spacer()
                Button {
                    addSegment(binding: binding)
                } label: {
                    Label("Add segment", systemImage: "plus")
                }
                .buttonStyle(.borderless)
                .controlSize(.small)
                .disabled(availableMetricName(for: chip) == nil)
            }
            segmentsListBody(chip: chip, binding: binding)
        }
    }

    private func segmentsListBody(chip: MenuBarChipConfig, binding: Binding<MenuBarChipConfig>) -> some View {
        ZStack(alignment: .topLeading) {
            VStack(spacing: 0) {
                ForEach(Array(chip.segments.enumerated()), id: \.element.id) { index, segment in
                    segmentRowContainer(
                        chip: chip,
                        chipBinding: binding,
                        segment: segment,
                        index: index
                    )
                }
            }
            .animation(.spring(response: 0.34, dampingFraction: 0.85), value: draggingSegmentID)
            .animation(.spring(response: 0.34, dampingFraction: 0.85), value: segmentDropIndex)

            segmentDropIndicator(chip: chip)
            segmentFloatingPreview(chip: chip)
        }
        .coordinateSpace(name: segmentListCoordinateSpace)
        .onPreferenceChange(SegmentRowFramePreferenceKey.self) { segmentRowFrames = $0 }
    }

    private func segmentRowContainer(
        chip: MenuBarChipConfig,
        chipBinding: Binding<MenuBarChipConfig>,
        segment: MenuBarChipSegmentConfig,
        index: Int
    ) -> some View {
        let isDragging = draggingSegmentID == segment.id
        return segmentRow(
            chip: chip,
            chipBinding: chipBinding,
            segment: segment,
            index: index
        )
        .background(
            GeometryReader { geo in
                Color.clear.preference(
                    key: SegmentRowFramePreferenceKey.self,
                    value: [segment.id: geo.frame(in: .named(segmentListCoordinateSpace))]
                )
            }
        )
        .opacity(isDragging ? 0.0 : 1.0)
        .frame(maxHeight: isDragging ? 0 : nil)
        .clipped()
    }

    @ViewBuilder
    private func segmentDropIndicator(chip: MenuBarChipConfig) -> some View {
        if let segmentDropIndex,
           let y = segmentDropIndicatorY(chip: chip, atIndex: segmentDropIndex) {
            Capsule()
                .fill(Color.accentColor)
                .frame(height: 2)
                .padding(.horizontal, 4)
                .offset(y: y - 1)
                .allowsHitTesting(false)
                .transition(.opacity)
        }
    }

    private func segmentDropIndicatorY(chip: MenuBarChipConfig, atIndex index: Int) -> CGFloat? {
        let visible = chip.segments.filter { $0.id != draggingSegmentID }
        guard let first = visible.first, let last = visible.last else { return 0 }
        let clamped = max(0, min(index, visible.count))
        if clamped == 0 {
            return segmentRowFrames[first.id]?.minY
        }
        if clamped >= visible.count {
            return segmentRowFrames[last.id]?.maxY
        }
        let prev = segmentRowFrames[visible[clamped - 1].id]?.maxY ?? 0
        let next = segmentRowFrames[visible[clamped].id]?.minY ?? prev
        return (prev + next) / 2
    }

    @ViewBuilder
    private func segmentFloatingPreview(chip: MenuBarChipConfig) -> some View {
        if let id = draggingSegmentID,
           let segment = chip.segments.first(where: { $0.id == id }),
           let frame = segmentRowFrames[id] {
            SegmentDragPreviewCard(metricName: segment.metricName)
                .frame(width: max(frame.width, 200))
                .offset(
                    x: frame.minX,
                    y: segmentDragCursorY - frame.height / 2
                )
                .allowsHitTesting(false)
                .transition(.opacity)
        }
    }

    // MARK: Segment drag handling

    private func handleSegmentDragChanged(value: DragGesture.Value, segmentID: UUID, chip: MenuBarChipConfig) {
        if draggingSegmentID == nil {
            withAnimation(.spring(response: 0.28, dampingFraction: 0.85)) {
                draggingSegmentID = segmentID
            }
            // Collapse any expanded segment so the drop indicator stays
            // visually anchored on uniform row heights.
            if expandedSegmentID != nil {
                expandedSegmentID = nil
            }
        }
        segmentDragCursorY = value.location.y
        segmentDropIndex = computeSegmentDropIndex(at: value.location.y, chip: chip)
    }

    private func handleSegmentDragEnded(value: DragGesture.Value, segmentID: UUID, binding: Binding<MenuBarChipConfig>) {
        let finalIndex = computeSegmentDropIndex(at: value.location.y, chip: binding.wrappedValue)
        performSegmentDrop(in: binding, draggedID: segmentID, toVisibleIndex: finalIndex)
        withAnimation(.spring(response: 0.34, dampingFraction: 0.82)) {
            draggingSegmentID = nil
            segmentDropIndex = nil
        }
    }

    private func computeSegmentDropIndex(at y: CGFloat, chip: MenuBarChipConfig) -> Int {
        let visible = chip.segments.filter { $0.id != draggingSegmentID }
        for (idx, s) in visible.enumerated() {
            guard let frame = segmentRowFrames[s.id] else { continue }
            if y < frame.midY {
                return idx
            }
        }
        return visible.count
    }

    private func performSegmentDrop(in binding: Binding<MenuBarChipConfig>, draggedID: UUID, toVisibleIndex visibleIndex: Int) {
        var chip = binding.wrappedValue
        guard let sourceIdx = chip.segments.firstIndex(where: { $0.id == draggedID }) else { return }
        let destOffset: Int
        if visibleIndex >= sourceIdx {
            destOffset = visibleIndex + 1
        } else {
            destOffset = visibleIndex
        }
        if destOffset == sourceIdx || destOffset == sourceIdx + 1 {
            return
        }
        chip.segments.move(fromOffsets: IndexSet(integer: sourceIdx), toOffset: destOffset)
        binding.wrappedValue = chip
    }

    private func segmentRow(
        chip: MenuBarChipConfig,
        chipBinding: Binding<MenuBarChipConfig>,
        segment: MenuBarChipSegmentConfig,
        index: Int
    ) -> some View {
        let isOnly = chip.segments.count == 1
        let expanded = expandedSegmentID == segment.id
        return VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                segmentDragHandle(
                    chip: chip,
                    chipBinding: chipBinding,
                    segmentID: segment.id,
                    enabled: !isOnly
                )
                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .rotationEffect(.degrees(expanded ? 90 : 0))
                Text(segment.metricName.isEmpty ? "(no metric)" : segment.metricName)
                    .font(.callout)
                Spacer(minLength: 0)
                Button {
                    moveSegment(in: chipBinding, from: index, to: index - 1)
                } label: { Image(systemName: "arrow.up") }
                .buttonStyle(.borderless)
                .disabled(index == 0)

                Button {
                    moveSegment(in: chipBinding, from: index, to: index + 1)
                } label: { Image(systemName: "arrow.down") }
                .buttonStyle(.borderless)
                .disabled(index >= chip.segments.count - 1)

                Button {
                    deleteSegment(in: chipBinding, segmentID: segment.id)
                } label: {
                    Image(systemName: "trash")
                        .foregroundStyle(isOnly ? Color.secondary : Color.red)
                }
                .buttonStyle(.borderless)
                .disabled(isOnly)
                .help(isOnly ? "A chip needs at least one segment" : "Delete segment")
            }
            .contentShape(Rectangle())
            .onTapGesture {
                withAnimation(.easeOut(duration: 0.16)) {
                    expandedSegmentID = expanded ? nil : segment.id
                }
            }
            .padding(.vertical, 4)

            if expanded {
                SegmentEditor(
                    preferences: preferences,
                    store: store,
                    chipID: chipID,
                    segmentID: segment.id,
                    isDark: isDark
                )
                .padding(.top, 6)
                .padding(.bottom, 8)
                .padding(.leading, 18)
            }
        }
        .padding(.horizontal, 8)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(Color.secondary.opacity(expanded ? 0.06 : 0.0))
        )
    }

    // MARK: Mutations on segments

    private func availableMetricName(for chip: MenuBarChipConfig) -> String? {
        let vendorEntries = store.entries.filter { $0.vendor == chip.vendor }
        let entry = vendorEntries.first(where: { $0.isActive }) ?? vendorEntries.first
        return entry?.metrics.compactMap(SegmentEditingHelpers.metricName).first
    }

    private func addSegment(binding: Binding<MenuBarChipConfig>) {
        let chip = binding.wrappedValue
        guard let metricName = availableMetricName(for: chip) else { return }
        let metric = store.entries
            .first(where: { $0.vendor == chip.vendor })?
            .metrics
            .first(where: { SegmentEditingHelpers.metricName($0) == metricName })
        let display: SegmentDisplay
        switch metric {
        case .some(.payAsYouGo):
            display = .payAsYouGo
        default:
            display = .timeWindow(TimeWindowDisplay(letter: MenuBarMetricLetter.defaultLetter(for: metricName)))
        }
        var newChip = chip
        newChip.segments.append(MenuBarChipSegmentConfig(
            account: .currentlyActive,
            metricName: metricName,
            display: display
        ))
        binding.wrappedValue = newChip
    }

    private func deleteSegment(in binding: Binding<MenuBarChipConfig>, segmentID: UUID) {
        var chip = binding.wrappedValue
        guard chip.segments.count > 1 else { return }
        chip.segments.removeAll { $0.id == segmentID }
        binding.wrappedValue = chip
        if expandedSegmentID == segmentID { expandedSegmentID = nil }
    }

    @ViewBuilder
    private func segmentDragHandle(
        chip: MenuBarChipConfig,
        chipBinding: Binding<MenuBarChipConfig>,
        segmentID: UUID,
        enabled: Bool
    ) -> some View {
        let base = Image(systemName: "line.3.horizontal")
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(enabled ? Color.secondary.opacity(0.7) : Color.secondary.opacity(0.25))
            .frame(width: 16, height: 22)
            .contentShape(Rectangle())
            .help(enabled ? "Drag to reorder" : "A chip needs at least one segment")
            .onHover { hovering in
                guard enabled else { return }
                if hovering { NSCursor.openHand.push() } else { NSCursor.pop() }
            }
        if enabled {
            base.gesture(
                DragGesture(minimumDistance: 4, coordinateSpace: .named(segmentListCoordinateSpace))
                    .onChanged { value in
                        handleSegmentDragChanged(value: value, segmentID: segmentID, chip: chip)
                    }
                    .onEnded { value in
                        handleSegmentDragEnded(value: value, segmentID: segmentID, binding: chipBinding)
                    }
            )
        } else {
            base
        }
    }

    private func moveSegment(in binding: Binding<MenuBarChipConfig>, from source: Int, to dest: Int) {
        var chip = binding.wrappedValue
        guard source >= 0, source < chip.segments.count,
              dest >= 0, dest < chip.segments.count else { return }
        let element = chip.segments.remove(at: source)
        chip.segments.insert(element, at: dest)
        binding.wrappedValue = chip
    }
}

// MARK: - Segment drag preview card

private struct SegmentDragPreviewCard: View {
    let metricName: String

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "line.3.horizontal")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.secondary)
            Text(metricName.isEmpty ? "(no metric)" : metricName)
                .font(.callout)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(.background)
                .shadow(color: .black.opacity(0.22), radius: 10, x: 0, y: 4)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.accentColor.opacity(0.5), lineWidth: 1)
        )
        .rotationEffect(.degrees(-1.0))
        .scaleEffect(1.02)
    }
}
