import SwiftUI
import AppKit
import AIUsagesTrackersLib

// PreferenceKey kept distinct from MenubarHintSettingsView and the top-level chart
// list so multiple scoped drag-reorder contexts can coexist in the same view tree.
private struct ChartSeriesRowFramePreferenceKey: PreferenceKey {
    static let defaultValue: [UUID: CGRect] = [:]
    static func reduce(value: inout [UUID: CGRect], nextValue: () -> [UUID: CGRect]) {
        value.merge(nextValue()) { _, new in new }
    }
}

struct ChartConfigurationEditor: View {
    @Bindable var store: UsageStore
    @Binding var configuration: ChartConfiguration

    // Drag state, scoped to this editor instance
    @State private var rowFrames: [UUID: CGRect] = [:]
    @State private var draggingID: UUID?
    @State private var dragCursorY: CGFloat = 0
    @State private var dropIndex: Int?

    private var coordinateSpaceName: String {
        "chart.series.\(configuration.id.uuidString)"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            nameRow

            Picker("Series", selection: selectionModeBinding) {
                Text("All available metrics").tag(ChartSelectionMode.allAvailable)
                Text("Custom").tag(ChartSelectionMode.custom)
            }
            .labelsHidden()
            .pickerStyle(.segmented)

            if case .custom = configuration.selection {
                customSeriesBlock
            }
        }
    }

    private var nameRow: some View {
        HStack(spacing: 8) {
            Text("Name")
                .font(.caption2)
                .fontWeight(.semibold)
                .tracking(0.8)
                .textCase(.uppercase)
                .foregroundStyle(.secondary)
                .frame(width: 56, alignment: .leading)
            TextField("Chart name", text: $configuration.title)
                .textFieldStyle(.roundedBorder)
        }
    }

    // MARK: Custom series block

    private var customSeriesBlock: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Text("Series")
                    .font(.caption2)
                    .fontWeight(.semibold)
                    .tracking(0.8)
                    .textCase(.uppercase)
                    .foregroundStyle(.secondary)
                Text("· drag the handle to reorder")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                Spacer()
                Button {
                    addSeries()
                } label: {
                    Label("Add series", systemImage: "plus")
                }
                .controlSize(.small)
                .disabled(availableVendors.isEmpty)
            }

            let series = customSeries
            if series.isEmpty {
                emptySeriesState
            } else {
                seriesListBody(series: series)
            }
        }
    }

    private var emptySeriesState: some View {
        Text("No custom series configured")
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(.vertical, 6)
    }

    private func seriesListBody(series: [ChartSeriesConfig]) -> some View {
        ZStack(alignment: .topLeading) {
            VStack(spacing: 6) {
                ForEach(Array(series.enumerated()), id: \.element.id) { index, item in
                    seriesRow(item: item, index: index)
                }
            }
            .animation(.spring(response: 0.34, dampingFraction: 0.85), value: draggingID)
            .animation(.spring(response: 0.34, dampingFraction: 0.85), value: dropIndex)

            dropIndicator(series: series)
            floatingPreview(series: series)
        }
        .coordinateSpace(name: coordinateSpaceName)
        .onPreferenceChange(ChartSeriesRowFramePreferenceKey.self) { rowFrames = $0 }
    }

    private func seriesRow(item: ChartSeriesConfig, index: Int) -> some View {
        let isDragging = draggingID == item.id
        return HStack(alignment: .top, spacing: 8) {
            Image(systemName: "line.3.horizontal")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary.opacity(0.7))
                .frame(width: 18, height: 24)
                .contentShape(Rectangle())
                .help("Drag to reorder")
                .onHover { hovering in
                    if hovering { NSCursor.openHand.push() } else { NSCursor.pop() }
                }
                .gesture(
                    DragGesture(minimumDistance: 4, coordinateSpace: .named(coordinateSpaceName))
                        .onChanged { value in handleDragChanged(value: value, seriesID: item.id) }
                        .onEnded { value in handleDragEnded(value: value, seriesID: item.id) }
                )

            ChartSeriesEditor(
                store: store,
                series: seriesBinding(at: index),
                onDuplicate: { duplicateSeries(at: index) },
                onDelete: { deleteSeries(at: index) }
            )
            .padding(10)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color(NSColor.controlBackgroundColor))
            )
        }
        .background(
            GeometryReader { geo in
                Color.clear.preference(
                    key: ChartSeriesRowFramePreferenceKey.self,
                    value: [item.id: geo.frame(in: .named(coordinateSpaceName))]
                )
            }
        )
        .opacity(isDragging ? 0.0 : 1.0)
        .frame(maxHeight: isDragging ? 0 : nil)
        .clipped()
    }

    // MARK: Drop indicator + floating preview

    @ViewBuilder
    private func dropIndicator(series: [ChartSeriesConfig]) -> some View {
        if let dropIndex, let y = dropIndicatorY(series: series, atIndex: dropIndex) {
            Capsule()
                .fill(Color.accentColor)
                .frame(height: 2)
                .padding(.horizontal, 4)
                .offset(y: y - 1)
                .allowsHitTesting(false)
                .transition(.opacity)
        }
    }

    private func dropIndicatorY(series: [ChartSeriesConfig], atIndex index: Int) -> CGFloat? {
        let visible = series.filter { $0.id != draggingID }
        guard !visible.isEmpty else { return 0 }
        let clamped = max(0, min(index, visible.count))
        if clamped == 0 {
            return rowFrames[visible[0].id]?.minY
        }
        if clamped >= visible.count {
            return rowFrames[visible.last!.id]?.maxY
        }
        let prev = rowFrames[visible[clamped - 1].id]?.maxY ?? 0
        let next = rowFrames[visible[clamped].id]?.minY ?? prev
        return (prev + next) / 2
    }

    @ViewBuilder
    private func floatingPreview(series: [ChartSeriesConfig]) -> some View {
        if let id = draggingID,
           let item = series.first(where: { $0.id == id }),
           let frame = rowFrames[id] {
            seriesDragPreview(item: item)
                .frame(width: max(frame.width, 200))
                .offset(x: frame.minX, y: dragCursorY - frame.height / 2)
                .allowsHitTesting(false)
        }
    }

    private func seriesDragPreview(item: ChartSeriesConfig) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "line.3.horizontal")
                .foregroundStyle(.secondary)
                .font(.system(size: 11, weight: .semibold))
            Path { path in
                path.move(to: CGPoint(x: 0, y: 8))
                path.addLine(to: CGPoint(x: 26, y: 8))
            }
            .stroke(item.style.color.swiftUIColor, style: item.style.lineStyle.strokeStyle)
            .frame(width: 26, height: 16)
            Text(item.label.isEmpty ? "\(item.vendor.rawValue) / \(item.metricName)" : item.label)
                .font(.callout)
                .fontWeight(.medium)
                .lineLimit(1)
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

    // MARK: Drag handling

    private func handleDragChanged(value: DragGesture.Value, seriesID: UUID) {
        if draggingID == nil {
            withAnimation(.spring(response: 0.28, dampingFraction: 0.85)) {
                draggingID = seriesID
            }
        }
        dragCursorY = value.location.y
        let series = customSeries
        dropIndex = computeDropIndex(at: value.location.y, series: series)
    }

    private func handleDragEnded(value: DragGesture.Value, seriesID: UUID) {
        let series = customSeries
        let finalIndex = computeDropIndex(at: value.location.y, series: series)
        performDrop(draggedID: seriesID, toVisibleIndex: finalIndex)
        withAnimation(.spring(response: 0.34, dampingFraction: 0.82)) {
            draggingID = nil
            dropIndex = nil
        }
    }

    private func computeDropIndex(at y: CGFloat, series: [ChartSeriesConfig]) -> Int {
        let visible = series.filter { $0.id != draggingID }
        for (idx, item) in visible.enumerated() {
            guard let frame = rowFrames[item.id] else { continue }
            if y < frame.midY { return idx }
        }
        return visible.count
    }

    private func performDrop(draggedID: UUID, toVisibleIndex visibleIndex: Int) {
        var series = customSeries
        guard let sourceIdx = series.firstIndex(where: { $0.id == draggedID }) else { return }
        let destOffset: Int
        if visibleIndex >= sourceIdx {
            destOffset = visibleIndex + 1
        } else {
            destOffset = visibleIndex
        }
        if destOffset == sourceIdx || destOffset == sourceIdx + 1 { return }
        series.move(fromOffsets: IndexSet(integer: sourceIdx), toOffset: destOffset)
        configuration.selection = .custom(series)
    }

    // MARK: Mutations

    private func addSeries() {
        guard let vendor = availableVendors.first else { return }
        let metricName = firstAvailableMetricName(for: vendor, account: .currentlyActive) ?? ""
        var series = customSeries
        series.append(
            ChartSeriesConfig(
                vendor: vendor,
                account: .currentlyActive,
                metricName: metricName,
                style: ChartSeriesStyle(
                    color: ChartSeriesColor.allCases[series.count % ChartSeriesColor.allCases.count],
                    lineStyle: .solid
                )
            )
        )
        configuration.selection = .custom(series)
    }

    private func duplicateSeries(at index: Int) {
        var series = customSeries
        guard series.indices.contains(index) else { return }
        let source = series[index]
        let copy = ChartSeriesConfig(
            vendor: source.vendor,
            account: source.account,
            metricName: source.metricName,
            label: source.label,
            style: source.style
        )
        series.insert(copy, at: index + 1)
        configuration.selection = .custom(series)
    }

    private func deleteSeries(at index: Int) {
        var series = customSeries
        guard series.indices.contains(index) else { return }
        series.remove(at: index)
        configuration.selection = .custom(series)
    }

    // MARK: Bindings + helpers

    private var selectionModeBinding: Binding<ChartSelectionMode> {
        Binding(
            get: {
                switch configuration.selection {
                case .allAvailable: .allAvailable
                case .custom: .custom
                }
            },
            set: { mode in
                switch mode {
                case .allAvailable:
                    configuration.selection = .allAvailable
                    if configuration.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        configuration.title = "All available metrics"
                    }
                case .custom:
                    configuration.selection = .custom(customSeries)
                }
            }
        )
    }

    private var customSeries: [ChartSeriesConfig] {
        if case .custom(let series) = configuration.selection {
            return series
        }
        return []
    }

    private func seriesBinding(at index: Int) -> Binding<ChartSeriesConfig> {
        Binding(
            get: { customSeries[index] },
            set: { newValue in
                var series = customSeries
                guard series.indices.contains(index) else { return }
                series[index] = newValue
                configuration.selection = .custom(series)
            }
        )
    }

    private var availableVendors: [Vendor] {
        Array(Set(store.entries.map(\.vendor))).sorted { $0.rawValue < $1.rawValue }
    }

    private func firstAvailableMetricName(for vendor: Vendor, account: AccountSelection) -> String? {
        let vendorEntries = store.entries.filter { $0.vendor == vendor }
        let entry: VendorUsageEntry?
        switch account {
        case .currentlyActive:
            entry = vendorEntries.first(where: { $0.isActive })
        case .specific(let email):
            entry = vendorEntries.first(where: { $0.account == email })
        }
        return entry?.metrics.compactMap(SegmentEditingHelpers.metricName).first
    }
}

enum ChartSelectionMode: Hashable {
    case allAvailable
    case custom
}
