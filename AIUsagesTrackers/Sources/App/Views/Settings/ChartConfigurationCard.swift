import SwiftUI
import AppKit
import AIUsagesTrackersLib

struct ChartConfigurationCard: View {
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

    private var configurationBinding: Binding<ChartConfiguration>? {
        SettingsConfigurationBindings.chartConfiguration(preferences: preferences, configurationID: configurationID)
    }

    var body: some View {
        if let configurationBinding {
            VStack(alignment: .leading, spacing: 0) {
                header(for: configurationBinding.wrappedValue)
                if isExpanded {
                    DeferredChartConfigurationEditor(
                        store: store,
                        configuration: configurationBinding
                    )
                    .padding(.top, 6)
                    .padding(.leading, 30)
                    .padding(.trailing, 4)
                    .padding(.bottom, 10)
                    .transition(.opacity)
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
            withAnimation(.easeOut(duration: 0.14)) { isExpanded.toggle() }
        }
    }

    private var chevron: some View {
        Image(systemName: "chevron.right")
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(.secondary)
            .rotationEffect(.degrees(isExpanded ? 90 : 0))
            .frame(width: 12)
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
}

private struct DeferredChartConfigurationEditor: View {
    @Bindable var store: UsageStore
    @Binding var configuration: ChartConfiguration
    @State private var isMounted = false

    var body: some View {
        Group {
            if isMounted {
                ChartConfigurationEditor(store: store, configuration: $configuration)
            } else {
                ProgressView()
                    .controlSize(.small)
                    .frame(maxWidth: .infinity, minHeight: 36, alignment: .center)
            }
        }
        .task(id: configuration.id) {
            isMounted = false
            await Task.yield()
            guard !Task.isCancelled else { return }
            isMounted = true
        }
        .onDisappear {
            isMounted = false
        }
    }
}
