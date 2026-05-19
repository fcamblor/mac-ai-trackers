import SwiftUI
import AIUsagesTrackersLib

struct ChartSeriesEditor: View {
    @Bindable var store: UsageStore
    @Binding var series: ChartSeriesConfig
    let onDuplicate: () -> Void
    let onDelete: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            headerRow
            MetricSelectionEditor(
                store: store,
                vendor: $series.vendor,
                account: $series.account,
                metricName: $series.metricName,
                layout: .grid
            )
            stylePanel
        }
    }

    private var headerRow: some View {
        HStack(spacing: 8) {
            seriesPreviewLine
            TextField("Series name (optional)", text: $series.label, prompt: Text(defaultSeriesLabel))
                .textFieldStyle(.roundedBorder)
            Button(action: onDuplicate) {
                Image(systemName: "plus.square.on.square")
            }
            .buttonStyle(.borderless)
            .help("Duplicate series")
            Button(action: onDelete) {
                Image(systemName: "trash")
                    .foregroundStyle(.red)
            }
            .buttonStyle(.borderless)
            .help("Delete series")
        }
    }

    private var seriesPreviewLine: some View {
        // Visual stub mirroring how the series will appear in the chart: a short
        // stroked line in the chosen color and style.
        Path { path in
            path.move(to: CGPoint(x: 0, y: 8))
            path.addLine(to: CGPoint(x: 26, y: 8))
        }
        .stroke(series.style.color.swiftUIColor, style: series.style.lineStyle.strokeStyle)
        .frame(width: 26, height: 16)
    }

    // MARK: Style panel

    private var stylePanel: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .center, spacing: 14) {
                styleSubLabel("Color")
                colorSwatches
            }
            HStack(alignment: .center, spacing: 14) {
                styleSubLabel("Line")
                lineStyleChips
            }
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(Color.secondary.opacity(0.07))
        )
    }

    private func styleSubLabel(_ text: String) -> some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(.secondary)
            .frame(width: 56, alignment: .leading)
    }

    private var colorSwatches: some View {
        HStack(spacing: 6) {
            ForEach(ChartSeriesColor.allCases) { color in
                colorSwatch(color: color)
            }
            Spacer(minLength: 0)
        }
    }

    private func colorSwatch(color: ChartSeriesColor) -> some View {
        let isSelected = series.style.color == color
        return Button {
            withAnimation(.easeOut(duration: 0.12)) {
                series.style.color = color
            }
        } label: {
            ZStack {
                Circle()
                    .strokeBorder(
                        isSelected ? Color.primary.opacity(0.9) : Color.clear,
                        lineWidth: 2
                    )
                    .frame(width: 26, height: 26)
                Circle()
                    .fill(color.swiftUIColor)
                    .frame(width: 18, height: 18)
            }
            .frame(width: 28, height: 28)
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help(color.displayName)
    }

    private var lineStyleChips: some View {
        HStack(spacing: 6) {
            ForEach(ChartLineStyle.allCases) { lineStyle in
                lineStyleChip(style: lineStyle)
            }
            Spacer(minLength: 0)
        }
    }

    private func lineStyleChip(style: ChartLineStyle) -> some View {
        let isSelected = series.style.lineStyle == style
        return Button {
            withAnimation(.easeOut(duration: 0.12)) {
                series.style.lineStyle = style
            }
        } label: {
            ZStack {
                RoundedRectangle(cornerRadius: 6)
                    .fill(isSelected ? Color.accentColor.opacity(0.14) : Color.clear)
                RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(
                        isSelected ? Color.accentColor.opacity(0.85) : Color.secondary.opacity(0.4),
                        lineWidth: 1
                    )
                Path { path in
                    path.move(to: CGPoint(x: 8, y: 13))
                    path.addLine(to: CGPoint(x: 48, y: 13))
                }
                .stroke(series.style.color.swiftUIColor, style: style.strokeStyle)
            }
            .frame(width: 56, height: 26)
            .contentShape(RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
        .help(style.displayName)
    }

    // MARK: Default label

    private var defaultSeriesLabel: String {
        let accountLabel: String
        switch series.account {
        case .currentlyActive:
            if let entry = store.entries.first(where: { $0.vendor == series.vendor && $0.isActive }) {
                accountLabel = entry.account.rawValue
            } else {
                accountLabel = "currently active"
            }
        case .specific(let email):
            accountLabel = email.rawValue
        }
        return "\(series.vendor.rawValue) / \(accountLabel) / \(series.metricName)"
    }
}
