import SwiftUI
import AppKit
import AIUsagesTrackersLib

struct ChartSettingsView: View {
    let preferences: UserDefaultsAppPreferences

    var body: some View {
        if let store = AppDelegate.sharedStore {
            ChartSettingsContent(preferences: preferences, store: store)
        } else {
            ContentUnavailableView(
                "Settings loading",
                systemImage: "hourglass",
                description: Text("Usage data is initializing. Close and reopen Settings.")
            )
        }
    }
}

// MARK: - Row frame preference key (distinct from segments + series)

private struct ChartRowFramePreferenceKey: PreferenceKey {
    static let defaultValue: [UUID: CGRect] = [:]
    static func reduce(value: inout [UUID: CGRect], nextValue: () -> [UUID: CGRect]) {
        value.merge(nextValue()) { _, new in new }
    }
}

// MARK: - Content

private struct ChartSettingsContent: View {
    let preferences: UserDefaultsAppPreferences
    @Bindable var store: UsageStore

    private static let coordinateSpaceName = "chartSettings.list"

    @State private var pendingDelete: UUID?

    // Drag state
    @State private var rowFrames: [UUID: CGRect] = [:]
    @State private var draggingID: UUID?
    @State private var dragCursorY: CGFloat = 0
    @State private var dropIndex: Int?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                headerSection
                Divider()
                chartList
            }
        }
        .confirmationDialog(
            deleteConfirmationTitle,
            isPresented: deleteConfirmationBinding,
            titleVisibility: .visible
        ) {
            Button("Delete chart", role: .destructive) {
                if let id = pendingDelete { delete(configurationID: id) }
                pendingDelete = nil
            }
            Button("Cancel", role: .cancel) { pendingDelete = nil }
        } message: {
            Text("This chart will no longer appear in the popover.")
        }
    }

    // MARK: Header

    private var headerSection: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 3) {
                Text("Charts")
                    .font(.headline)
                Text("Configure the charts shown in the history tab.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(16)
    }

    // MARK: List

    @ViewBuilder
    private var chartList: some View {
        if preferences.chartConfigurations.isEmpty {
            emptyState
        } else {
            populatedList
        }
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Spacer(minLength: 24)
            Text("No chart configured")
                .font(.headline)
            Text("The history tab will be empty until you add a chart.")
                .font(.caption)
                .foregroundStyle(.secondary)
            Button {
                addConfiguration()
            } label: {
                Label("Add your first chart", systemImage: "plus")
            }
            Spacer(minLength: 24)
        }
        .frame(maxWidth: .infinity)
        .padding(16)
    }

    private var populatedList: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Charts")
                    .font(.headline)
                Text("· drag the handle to reorder")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                Spacer()
                Button {
                    addConfiguration()
                } label: {
                    Label("Add", systemImage: "plus")
                }
            }
            .padding(.bottom, 2)

            listBody
        }
        .padding(.horizontal, 16)
        .padding(.top, 12)
        .padding(.bottom, 16)
    }

    private var listBody: some View {
        let configurations = preferences.chartConfigurations
        return ZStack(alignment: .topLeading) {
            VStack(spacing: 4) {
                ForEach(Array(configurations.enumerated()), id: \.element.id) { index, configuration in
                    rowContainer(configuration: configuration, index: index, count: configurations.count)
                }
            }
            .animation(.spring(response: 0.34, dampingFraction: 0.85), value: draggingID)
            .animation(.spring(response: 0.34, dampingFraction: 0.85), value: dropIndex)

            dropIndicator(configurations: configurations)
            floatingPreview(configurations: configurations)
        }
        .coordinateSpace(name: Self.coordinateSpaceName)
        .onPreferenceChange(ChartRowFramePreferenceKey.self) { rowFrames = $0 }
    }

    private func rowContainer(configuration: ChartConfiguration, index: Int, count: Int) -> some View {
        let isDragging = draggingID == configuration.id
        return ChartConfigurationCard(
            preferences: preferences,
            store: store,
            configurationID: configuration.id,
            canMoveUp: index > 0,
            canMoveDown: index < count - 1,
            onMoveUp: { move(from: index, to: index - 1) },
            onMoveDown: { move(from: index, to: index + 2) },
            onDuplicate: { duplicate(configurationID: configuration.id) },
            onRequestDelete: { pendingDelete = configuration.id },
            isBeingDragged: isDragging,
            dragCoordinateSpace: Self.coordinateSpaceName,
            onDragChanged: { value in handleDragChanged(value: value, configurationID: configuration.id) },
            onDragEnded: { value in handleDragEnded(value: value, configurationID: configuration.id) }
        )
        .background(
            GeometryReader { geo in
                Color.clear.preference(
                    key: ChartRowFramePreferenceKey.self,
                    value: [configuration.id: geo.frame(in: .named(Self.coordinateSpaceName))]
                )
            }
        )
        .opacity(isDragging ? 0.0 : 1.0)
        .frame(maxHeight: isDragging ? 0 : nil)
        .clipped()
    }

    // MARK: Drop indicator + floating preview

    @ViewBuilder
    private func dropIndicator(configurations: [ChartConfiguration]) -> some View {
        if let dropIndex, let y = dropIndicatorY(configurations: configurations, atIndex: dropIndex) {
            Capsule()
                .fill(Color.accentColor)
                .frame(height: 2)
                .padding(.horizontal, 4)
                .offset(y: y - 1)
                .allowsHitTesting(false)
        }
    }

    private func dropIndicatorY(configurations: [ChartConfiguration], atIndex index: Int) -> CGFloat? {
        let visible = configurations.filter { $0.id != draggingID }
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
    private func floatingPreview(configurations: [ChartConfiguration]) -> some View {
        if let id = draggingID,
           let configuration = configurations.first(where: { $0.id == id }),
           let frame = rowFrames[id] {
            ChartDragPreviewCard(configuration: configuration)
                .frame(width: max(frame.width, 240))
                .offset(x: frame.minX, y: dragCursorY - frame.height / 2)
                .allowsHitTesting(false)
        }
    }

    // MARK: Drag handling

    private func handleDragChanged(value: DragGesture.Value, configurationID: UUID) {
        if draggingID == nil {
            withAnimation(.spring(response: 0.28, dampingFraction: 0.85)) {
                draggingID = configurationID
            }
        }
        dragCursorY = value.location.y
        let configurations = preferences.chartConfigurations
        dropIndex = computeDropIndex(at: value.location.y, configurations: configurations)
    }

    private func handleDragEnded(value: DragGesture.Value, configurationID: UUID) {
        let configurations = preferences.chartConfigurations
        let finalIndex = computeDropIndex(at: value.location.y, configurations: configurations)
        performDrop(draggedID: configurationID, toVisibleIndex: finalIndex)
        withAnimation(.spring(response: 0.34, dampingFraction: 0.82)) {
            draggingID = nil
            dropIndex = nil
        }
    }

    private func computeDropIndex(at y: CGFloat, configurations: [ChartConfiguration]) -> Int {
        let visible = configurations.filter { $0.id != draggingID }
        for (idx, configuration) in visible.enumerated() {
            guard let frame = rowFrames[configuration.id] else { continue }
            if y < frame.midY { return idx }
        }
        return visible.count
    }

    private func performDrop(draggedID: UUID, toVisibleIndex visibleIndex: Int) {
        var configurations = preferences.chartConfigurations
        guard let sourceIdx = configurations.firstIndex(where: { $0.id == draggedID }) else { return }
        let destOffset: Int
        if visibleIndex >= sourceIdx {
            destOffset = visibleIndex + 1
        } else {
            destOffset = visibleIndex
        }
        if destOffset == sourceIdx || destOffset == sourceIdx + 1 { return }
        configurations.move(fromOffsets: IndexSet(integer: sourceIdx), toOffset: destOffset)
        preferences.chartConfigurations = configurations
    }

    // MARK: Mutations

    private func addConfiguration() {
        preferences.chartConfigurations.append(ChartConfigurationsSeeder.defaultConfigurations()[0])
    }

    private func duplicate(configurationID: UUID) {
        var configurations = preferences.chartConfigurations
        guard let idx = configurations.firstIndex(where: { $0.id == configurationID }) else { return }
        let source = configurations[idx]
        let copy = ChartConfiguration(
            title: duplicateTitle(from: source.title),
            selection: source.selection
        )
        configurations.insert(copy, at: idx + 1)
        preferences.chartConfigurations = configurations
    }

    private func duplicateTitle(from original: String) -> String {
        let trimmed = original.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "Untitled (copy)" : "\(trimmed) (copy)"
    }

    private func delete(configurationID: UUID) {
        preferences.chartConfigurations.removeAll { $0.id == configurationID }
    }

    private func move(from source: Int, to destination: Int) {
        var configurations = preferences.chartConfigurations
        guard source >= 0, source < configurations.count else { return }
        let dest = max(0, min(destination, configurations.count))
        configurations.move(fromOffsets: IndexSet(integer: source), toOffset: dest)
        preferences.chartConfigurations = configurations
    }

    // MARK: Confirmation

    private var deleteConfirmationBinding: Binding<Bool> {
        Binding(
            get: { pendingDelete != nil },
            set: { if !$0 { pendingDelete = nil } }
        )
    }

    private var deleteConfirmationTitle: String {
        guard let id = pendingDelete,
              let configuration = preferences.chartConfigurations.first(where: { $0.id == id }) else {
            return "Delete chart?"
        }
        return "Delete \(configuration.title) chart?"
    }
}

// MARK: - Drag preview card

private struct ChartDragPreviewCard: View {
    let configuration: ChartConfiguration

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "line.3.horizontal")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
            Image(systemName: "chart.xyaxis.line")
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(configuration.title.isEmpty ? "Untitled chart" : configuration.title)
                    .font(.body)
                    .fontWeight(.semibold)
                    .lineLimit(1)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            if case .custom(let series) = configuration.selection, !series.isEmpty {
                HStack(spacing: 2) {
                    ForEach(series.prefix(4)) { item in
                        Circle()
                            .fill(item.style.color.swiftUIColor)
                            .frame(width: 8, height: 8)
                    }
                }
            }
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

    private var subtitle: String {
        switch configuration.selection {
        case .allAvailable: return "All available metrics"
        case .custom(let series): return series.isEmpty ? "No series" : "\(series.count) series"
        }
    }
}
