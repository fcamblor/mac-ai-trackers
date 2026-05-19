import SwiftUI
import AppKit
import Foundation
import AIUsagesTrackersLib

// PreferenceKey kept distinct from MenubarHintSettingsView and the top-level chart
// list so multiple scoped drag-reorder contexts can coexist in the same view tree.
private struct ChartSeriesRowFramePreferenceKey: PreferenceKey {
    static let defaultValue: [UUID: CGRect] = [:]
    static func reduce(value: inout [UUID: CGRect], nextValue: () -> [UUID: CGRect]) {
        value.merge(nextValue()) { _, new in new }
    }
}

// The cursor position during a drag is updated on every mouse move (60+ Hz). Storing it
// as `@State` on `ChartConfigurationEditor` re-evaluated the whole editor body — and the
// embedded ChartSeriesEditor rows with their AppKit Pickers — at each tick, which is the
// dominant cost of the drag stutter. Wrapping the value in a dedicated ObservableObject
// scopes the subscription to the floating preview only: the parent body stays still.
@MainActor
private final class DragCursorTracker: ObservableObject {
    @Published var y: CGFloat = 0
}

struct ChartConfigurationEditor: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private static let hydrationBatchSize = 4

    @Bindable var store: UsageStore
    @Binding var configuration: ChartConfiguration

    // Drag state, scoped to this editor instance
    @State private var rowFrames: [UUID: CGRect] = [:]
    @State private var draggingID: UUID?
    @State private var dropIndex: Int?
    @State private var renderedSeriesCount: Int?
    @StateObject private var cursorTracker = DragCursorTracker()

    private var coordinateSpaceName: String {
        "chart.series.\(configuration.id.uuidString)"
    }

    private var metricOptions: MetricSelectionOptions {
        MetricSelectionOptions(entries: store.entries)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            editorHeader

            if case .custom = configuration.selection {
                customSeriesBlock
            }
        }
        .task(id: seriesHydrationKey) {
            await hydrateSeriesRows()
        }
    }

    private var editorHeader: some View {
        VStack(alignment: .leading, spacing: 12) {
            nameRow

            Picker("Series", selection: selectionModeBinding) {
                Text("All available metrics").tag(ChartSelectionMode.allAvailable)
                Text("Custom").tag(ChartSelectionMode.custom)
            }
            .labelsHidden()
            .pickerStyle(.segmented)
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
                let visibleSeriesCount = renderedSeriesCount ?? min(series.count, Self.hydrationBatchSize)
                seriesListBody(
                    series: Array(series.prefix(visibleSeriesCount)),
                    allSeries: series,
                    metricOptions: metricOptions
                )
            }
        }
        .transaction { transaction in
            transaction.animation = nil
        }
    }

    private var emptySeriesState: some View {
        Text("No custom series configured")
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(.vertical, 6)
    }

    private func seriesListBody(
        series: [ChartSeriesConfig],
        allSeries: [ChartSeriesConfig],
        metricOptions: MetricSelectionOptions
    ) -> some View {
        ZStack(alignment: .topLeading) {
            LazyVStack(spacing: 6) {
                ForEach(Array(series.enumerated()), id: \.element.id) { index, item in
                    ChartSeriesRow(
                        item: item,
                        isDragging: draggingID == item.id,
                        store: store,
                        options: metricOptions,
                        coordinateSpaceName: coordinateSpaceName,
                        onItemChange: { newValue in updateSeries(at: index, with: newValue) },
                        onDuplicate: { duplicateSeries(at: index) },
                        onDelete: { deleteSeries(at: index) },
                        onDragChanged: { value in handleDragChanged(value: value, seriesID: item.id) },
                        onDragEnded: { value in handleDragEnded(value: value, seriesID: item.id) }
                    )
                    .equatable()
                    .transition(seriesRowInsertionTransition)
                }
            }
            .animation(reduceMotion ? nil : .easeOut(duration: 0.16), value: renderedSeriesCount)
            .animation(.spring(response: 0.34, dampingFraction: 0.85), value: draggingID)
            .animation(.spring(response: 0.34, dampingFraction: 0.85), value: dropIndex)

            dropIndicator(series: allSeries)
            floatingPreview(series: allSeries)
        }
        .coordinateSpace(name: coordinateSpaceName)
        .onPreferenceChange(ChartSeriesRowFramePreferenceKey.self) { rowFrames = $0 }
    }

    private var seriesRowInsertionTransition: AnyTransition {
        guard !reduceMotion else { return .identity }
        return .asymmetric(
            insertion: .opacity.combined(with: .scale(scale: 0.985, anchor: .top)),
            removal: .opacity
        )
    }

    private var seriesHydrationKey: String {
        guard case .custom(let series) = configuration.selection else {
            return "\(configuration.id.uuidString):all"
        }
        let stableIDs = series.map(\.id.uuidString).sorted().joined(separator: ",")
        return "\(configuration.id.uuidString):\(stableIDs)"
    }

    private func hydrateSeriesRows() async {
        guard case .custom(let series) = configuration.selection else {
            renderedSeriesCount = nil
            return
        }
        let total = series.count
        let shouldLogPerformance = Loggers.app.effectiveMinLevel <= .debug
        let startedAt = shouldLogPerformance ? DispatchTime.now().uptimeNanoseconds : 0
        let chartID = String(configuration.id.uuidString.prefix(8))
        guard total > 0 else { return }

        if shouldLogPerformance {
            Loggers.app.log(
                .debug,
                "ChartSettingsPerf: hydrateSeriesRows start chart=\(chartID) "
                    + "totalSeries=\(total) batchSize=\(Self.hydrationBatchSize) reduceMotion=\(reduceMotion)"
            )
        }

        let currentCount = renderedSeriesCount ?? Self.hydrationBatchSize
        let initialCount = min(total, max(currentCount, Self.hydrationBatchSize))
        renderedSeriesCount = initialCount
        logHydrationProgress(chartID: chartID, startedAt: startedAt, rendered: initialCount, total: total)

        await Task.yield()
        guard !Task.isCancelled else { return }

        while (renderedSeriesCount ?? 0) < total {
            try? await Task.sleep(nanoseconds: reduceMotion ? 1_000_000 : 14_000_000)
            guard !Task.isCancelled else { return }
            let nextCount = min(total, (renderedSeriesCount ?? 0) + Self.hydrationBatchSize)
            renderedSeriesCount = nextCount
            logHydrationProgress(chartID: chartID, startedAt: startedAt, rendered: nextCount, total: total)
        }
    }

    private func logHydrationProgress(chartID: String, startedAt: UInt64, rendered: Int, total: Int) {
        guard Loggers.app.effectiveMinLevel <= .debug else { return }
        let elapsedMillis = Double(DispatchTime.now().uptimeNanoseconds - startedAt) / 1_000_000
        let elapsed = String(format: "%.2f", elapsedMillis)
        Loggers.app.log(
            .debug,
            "ChartSettingsPerf: hydrateSeriesRows progress chart=\(chartID) "
                + "renderedSeries=\(rendered)/\(total) elapsedMs=\(elapsed)"
        )
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
            FloatingDragPreview(tracker: cursorTracker, item: item, frame: frame)
        }
    }

    // MARK: Drag handling

    private func handleDragChanged(value: DragGesture.Value, seriesID: UUID) {
        if draggingID == nil {
            draggingID = seriesID
        }
        // Route the high-frequency cursor update through cursorTracker so only the
        // floating preview re-renders. `dropIndex` is updated only when it actually
        // changes — most drag frames stay inside the same slot.
        cursorTracker.y = value.location.y
        let series = customSeries
        let newDropIndex = computeDropIndex(at: value.location.y, series: series)
        if newDropIndex != dropIndex {
            dropIndex = newDropIndex
        }
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

    private func updateSeries(at index: Int, with newValue: ChartSeriesConfig) {
        var series = customSeries
        guard series.indices.contains(index) else { return }
        series[index] = newValue
        configuration.selection = .custom(series)
    }

    private var availableVendors: [Vendor] {
        metricOptions.availableVendors
    }

    private func firstAvailableMetricName(for vendor: Vendor, account: AccountSelection) -> String? {
        metricOptions.firstMetricName(vendor: vendor, account: account)
    }
}

enum ChartSelectionMode: Hashable {
    case allAvailable
    case custom
}

// Extracted as a struct with Equatable conformance so `.equatable()` can short-circuit
// SwiftUI's diffing during a drag: when only `dragCursorY` changes on the parent, the
// parent's body is re-evaluated, but rows whose `item`/`isDragging` are unchanged keep
// their previous body (including the embedded `ChartSeriesEditor` + `MetricSelectionEditor`
// pickers). Without this, every drag frame rebuilds the whole row tree and stutters.
private struct ChartSeriesRow: View, Equatable {
    let item: ChartSeriesConfig
    let isDragging: Bool
    let store: UsageStore
    let options: MetricSelectionOptions
    let coordinateSpaceName: String
    let onItemChange: (ChartSeriesConfig) -> Void
    let onDuplicate: () -> Void
    let onDelete: () -> Void
    let onDragChanged: (DragGesture.Value) -> Void
    let onDragEnded: (DragGesture.Value) -> Void

    // Closures and the `@Bindable` store are intentionally excluded from equality:
    // they are stable for a given row identity during a drag, and SwiftUI's
    // @Bindable handles store mutations independently.
    nonisolated static func == (lhs: ChartSeriesRow, rhs: ChartSeriesRow) -> Bool {
        lhs.item == rhs.item && lhs.isDragging == rhs.isDragging && lhs.options == rhs.options
    }

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
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
                        .onChanged(onDragChanged)
                        .onEnded(onDragEnded)
                )

            ChartSeriesEditor(
                store: store,
                series: Binding(
                    get: { item },
                    set: { newValue in onItemChange(newValue) }
                ),
                options: options,
                onDuplicate: onDuplicate,
                onDelete: onDelete
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
        .onAppear {
            guard Loggers.app.effectiveMinLevel <= .debug else { return }
            let seriesID = String(item.id.uuidString.prefix(8))
            let accountOptionsCount = options.availableAccounts(for: item.vendor).count
            let metricOptionsCount = options.availableMetrics(vendor: item.vendor, account: item.account).count
            Loggers.app.log(
                .debug,
                "ChartSettingsPerf: ChartSeriesRow appeared series=\(seriesID) vendor=\(item.vendor.rawValue) "
                    + "accountOptions=\(accountOptionsCount) metricOptions=\(metricOptionsCount)"
            )
        }
    }
}

// Scoped to the cursor tracker so SwiftUI only re-evaluates this view at each drag tick,
// not the entire ChartConfigurationEditor with its picker-heavy series rows.
private struct FloatingDragPreview: View {
    @ObservedObject var tracker: DragCursorTracker
    let item: ChartSeriesConfig
    let frame: CGRect

    var body: some View {
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
        .frame(width: max(frame.width, 200))
        .offset(x: frame.minX, y: tracker.y - frame.height / 2)
        .allowsHitTesting(false)
    }
}
