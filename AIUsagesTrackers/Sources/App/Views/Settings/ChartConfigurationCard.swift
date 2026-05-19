import SwiftUI
import AppKit
import AIUsagesTrackersLib

private struct ChartConfigurationEditorHeightPreferenceKey: PreferenceKey {
    static let defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

struct ChartConfigurationCard: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    let preferences: UserDefaultsAppPreferences
    @Bindable var store: UsageStore
    let configurationID: UUID
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
    @State private var shouldMountEditor: Bool = false
    @State private var editorMeasuredHeight: CGFloat = 0

    private var configurationBinding: Binding<ChartConfiguration>? {
        SettingsConfigurationBindings.chartConfiguration(preferences: preferences, configurationID: configurationID)
    }

    private var expansionAnimation: Animation? {
        reduceMotion ? .easeOut(duration: 0.08) : .spring(response: 0.36, dampingFraction: 0.9)
    }

    var body: some View {
        if let configurationBinding {
            VStack(alignment: .leading, spacing: 0) {
                header(for: configurationBinding.wrappedValue)
                if shouldMountEditor {
                    ChartConfigurationEditor(
                        store: store,
                        configuration: configurationBinding
                    )
                    .padding(.top, 6)
                    .padding(.leading, 30)
                    .padding(.trailing, 4)
                    .padding(.bottom, 10)
                    .background(
                        GeometryReader { proxy in
                            Color.clear.preference(
                                key: ChartConfigurationEditorHeightPreferenceKey.self,
                                value: proxy.size.height
                            )
                        }
                    )
                    .frame(height: isExpanded ? editorMeasuredHeight : 0, alignment: .top)
                    .clipped()
                    .allowsHitTesting(isExpanded)
                    .accessibilityHidden(!isExpanded)
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
            .onHover { hovering in
                isHovering = hovering
                if hovering {
                    shouldMountEditor = true
                }
            }
            .task(id: configurationID) {
                await Task.yield()
                guard !Task.isCancelled else { return }
                shouldMountEditor = true
            }
            .onPreferenceChange(ChartConfigurationEditorHeightPreferenceKey.self) { height in
                guard height > 0, abs(editorMeasuredHeight - height) > 0.5 else { return }
                editorMeasuredHeight = height
            }
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
            .animation(expansionAnimation, value: isExpanded)
            .animation(expansionAnimation, value: editorMeasuredHeight)
        }
    }

    private var rowBackground: Color {
        if isExpanded { return Color.secondary.opacity(0.07) }
        return isHovering ? Color.secondary.opacity(0.05) : Color.clear
    }

    // MARK: Header

    private func header(for configuration: ChartConfiguration) -> some View {
        HStack(spacing: 8) {
            dragHandle
            disclosureArea(for: configuration)
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

    private func disclosureArea(for configuration: ChartConfiguration) -> some View {
        HStack(spacing: 8) {
            chevron
            summary(for: configuration)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .onTapGesture {
            toggleExpansion()
        }
    }

    private var chevron: some View {
        Image(systemName: "chevron.right")
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(.secondary)
            .rotationEffect(.degrees(isExpanded ? 90 : 0))
            .frame(width: 12)
            .animation(.easeOut(duration: 0.12), value: isExpanded)
    }

    private func summary(for configuration: ChartConfiguration) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 8) {
                Image(systemName: "chart.xyaxis.line")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Text(configuration.title.isEmpty ? "Untitled chart" : configuration.title)
                    .font(.body)
                    .fontWeight(.medium)
                    .lineLimit(1)
            }
            HStack(spacing: 6) {
                Text(summaryLabel(for: configuration))
                if case .custom(let series) = configuration.selection, !series.isEmpty {
                    Text("·").foregroundStyle(.tertiary)
                    seriesColorStrip(series: series)
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }

    private func summaryLabel(for configuration: ChartConfiguration) -> String {
        switch configuration.selection {
        case .allAvailable:
            return "All available metrics"
        case .custom(let series):
            return series.count == 0
                ? "No custom series yet"
                : "\(series.count) custom series"
        }
    }

    private func seriesColorStrip(series: [ChartSeriesConfig]) -> some View {
        HStack(spacing: 2) {
            ForEach(series.prefix(6)) { item in
                Circle()
                    .fill(item.style.color.swiftUIColor)
                    .frame(width: 8, height: 8)
            }
            if series.count > 6 {
                Text("+\(series.count - 6)")
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(.tertiary)
            }
        }
    }

    private var actions: some View {
        HStack(spacing: 2) {
            Button(action: onDuplicate) {
                Image(systemName: "plus.square.on.square")
            }
            .buttonStyle(.borderless)
            .help("Duplicate chart")

            Button(action: onRequestDelete) {
                Image(systemName: "trash")
                    .foregroundStyle(.red)
            }
            .buttonStyle(.borderless)
            .help("Delete chart")
        }
        .opacity(isHovering || isExpanded ? 1.0 : 0.45)
    }

    private func toggleExpansion() {
        if isExpanded {
            withAnimation(expansionAnimation) {
                isExpanded = false
            }
        } else {
            shouldMountEditor = true
            withAnimation(expansionAnimation) {
                isExpanded = true
            }
        }
    }
}
