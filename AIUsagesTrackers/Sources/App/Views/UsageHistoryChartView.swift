import Charts
import SwiftUI
import AIUsagesTrackersLib

struct UsageHistoryChartView: View {
    let snapshot: UsageHistorySnapshot
    let referenceDate: Date
    @Binding var selectedWindow: UsageHistoryTimeWindow
    let isLoading: Bool
    let configurations: [ChartConfiguration]
    let currentEntries: [VendorUsageEntry]
    let onPreviousWindow: () -> Void
    let onNextWindow: () -> Void

    private var points: [UsageHistoryPoint] { snapshot.points }

    private var canNavigatePrevious: Bool {
        selectedWindow != .all && snapshot.hasDataBeforeWindow
    }

    private var canNavigateNext: Bool {
        selectedWindow != .all && snapshot.hasDataAfterWindow
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            controls

            if isLoading, points.isEmpty {
                loadingState
            } else if points.isEmpty {
                emptyState
            } else if configurations.isEmpty {
                noConfiguredChartsState
            } else {
                ForEach(configurations) { configuration in
                    UsageHistoryChartPanel(
                        configuration: configuration,
                        points: points,
                        currentEntries: currentEntries,
                        referenceDate: referenceDate,
                        selectedWindow: selectedWindow
                    )
                }
                if snapshot.skippedLineCount > 0 {
                    skippedLinesNotice
                }
            }
        }
        .padding(12)
    }

    private var controls: some View {
        HStack(spacing: 8) {
            Button {
                onPreviousWindow()
            } label: {
                Image(systemName: "chevron.left")
                    .frame(width: 16, height: 16)
                    .hoverAffordance(isEnabled: canNavigatePrevious)
            }
            .buttonStyle(.borderless)
            .controlSize(.small)
            .disabled(!canNavigatePrevious)
            .help("Previous time window")
            .focusable(false)

            Picker("History window", selection: $selectedWindow) {
                ForEach(UsageHistoryTimeWindow.allCases) { window in
                    Text(window.label).tag(window)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .controlSize(.small)

            Button {
                onNextWindow()
            } label: {
                Image(systemName: "chevron.right")
                    .frame(width: 16, height: 16)
                    .hoverAffordance(isEnabled: canNavigateNext)
            }
            .buttonStyle(.borderless)
            .controlSize(.small)
            .disabled(!canNavigateNext)
            .help("Next time window")
            .focusable(false)
        }
    }

    private var loadingState: some View {
        VStack(spacing: 8) {
            ProgressView()
                .controlSize(.small)
            Text("Loading history...")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 40)
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Text("No history yet")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
            Text("Snapshots will appear after the app records usage history.")
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 32)
    }

    private var noConfiguredChartsState: some View {
        VStack(spacing: 8) {
            Text("No chart configured")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
            Text("Add a chart in Settings to show usage history.")
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 32)
    }

    private var skippedLinesNotice: some View {
        Text("\(snapshot.skippedLineCount) malformed history line(s) skipped")
            .font(.system(size: 10))
            .foregroundStyle(.tertiary)
            .lineLimit(1)
    }
}

private struct UsageHistoryChartPanel: View {
    let configuration: ChartConfiguration
    let points: [UsageHistoryPoint]
    let currentEntries: [VendorUsageEntry]
    let referenceDate: Date
    let selectedWindow: UsageHistoryTimeWindow

    @State private var hoveredDate: Date?
    @State private var hoverIsLeftHalf = true

    private var series: [ResolvedChartSeries] {
        ChartSeriesResolver.resolve(
            configuration: configuration,
            points: points,
            currentEntries: currentEntries
        )
    }

    private var visiblePoints: [ChartPoint] {
        series.flatMap { series in
            var segmentIndex = 0
            return series.points.map { point in
                let item = ChartPoint(
                    seriesID: series.id,
                    segmentID: "\(series.id)|segment|\(segmentIndex)",
                    point: point
                )
                if point.value == nil {
                    segmentIndex += 1
                }
                return item
            }
        }
    }

    private var plottedPoints: [PlottedChartPoint] {
        visiblePoints.compactMap { item in
            guard let value = item.point.value else { return nil }
            return PlottedChartPoint(chartPoint: item, value: value)
        }
    }

    private var summaries: [UsageHistorySeriesSummary] {
        series.compactMap { series in
            guard let latest = series.points
                .filter({ $0.value != nil })
                .max(by: { $0.timestamp < $1.timestamp }),
                let latestValue = latest.value else { return nil }
            return UsageHistorySeriesSummary(
                id: series.id,
                label: series.label,
                metricName: latest.metricName,
                latestValue: latestValue,
                unit: latest.unit,
                pointCount: series.points.filter { $0.value != nil }.count
            )
        }
    }

    private var yAxisLabel: String {
        let units = Set(plottedPoints.map(\.point.unit).filter { !$0.isEmpty })
        if units.count == 1, let unit = units.first {
            return unit == "%" ? "Usage (%)" : "Usage (\(unit))"
        }
        return "Usage"
    }

    private var xDomain: ClosedRange<Date> {
        if let startDate = selectedWindow.startDate(relativeTo: referenceDate) {
            return startDate...referenceDate
        }

        let sorted = plottedPoints.map(\.point.timestamp).sorted()
        guard let first = sorted.first,
              let last = sorted.last else {
            return referenceDate.addingTimeInterval(-60 * 60)...referenceDate
        }
        if first == last {
            return first.addingTimeInterval(-30 * 60)...last.addingTimeInterval(30 * 60)
        }
        return first...last
    }

    private var seriesStyles: [String: ChartSeriesStyle] {
        Dictionary(uniqueKeysWithValues: series.enumerated().map { index, series in
            let style = series.style ?? ChartSeriesStyle(
                color: ChartSeriesColor.allCases[index % ChartSeriesColor.allCases.count],
                lineStyle: .solid
            )
            return (series.id, style)
        })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(configuration.title)
                .font(.system(size: 12, weight: .semibold))
                .lineLimit(1)

            if plottedPoints.isEmpty {
                noMatchingSeriesState
            } else {
                chart
            }
        }
    }

    private var chart: some View {
        Chart {
            ForEach(plottedPoints) { item in
                LineMark(
                    x: .value("Time", item.point.timestamp),
                    y: .value(yAxisLabel, item.value),
                    series: .value("Metric segment", item.segmentID)
                )
                .interpolationMethod(.catmullRom)
                .foregroundStyle(seriesColor(for: item.seriesID))
                .lineStyle(lineStyle(for: item.seriesID))
            }

            if let date = hoveredDate {
                RuleMark(x: .value("Hover", date))
                    .foregroundStyle(Color.primary.opacity(0.3))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 2]))
                    .annotation(
                        position: hoverIsLeftHalf ? .trailing : .leading,
                        alignment: .top,
                        spacing: 4
                    ) {
                        hoverTooltipView(for: date)
                    }
            }
        }
        .chartLegend(.hidden)
        .chartYAxisLabel(yAxisLabel)
        .chartXScale(domain: xDomain)
        .chartOverlay { proxy in
            GeometryReader { geometry in
                Rectangle().fill(.clear).contentShape(Rectangle())
                    .onContinuousHover { phase in
                        switch phase {
                        case .active(let location):
                            hoveredDate = proxy.value(atX: location.x, as: Date.self)
                            hoverIsLeftHalf = location.x < geometry.size.width / 2
                        case .ended:
                            hoveredDate = nil
                        }
                    }
            }
        }
        .frame(height: 180)
        .padding(8)
        .background(Color(NSColor.controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(Color.primary.opacity(0.16), lineWidth: 1)
        )
    }

    @ViewBuilder
    private func hoverTooltipView(for date: Date) -> some View {
        let items = nearestHoverPoints(at: date)
        if !items.isEmpty {
            VStack(alignment: .leading, spacing: 3) {
                Text(formatHoverDate(date))
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
                ForEach(items, id: \.seriesID) { item in
                    HStack(spacing: 4) {
                        seriesSwatch(for: item.seriesID)
                        Text(item.label)
                            .font(.system(size: 9))
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer(minLength: 4)
                        Text(format(value: item.value, unit: item.unit))
                            .font(.system(size: 9, weight: .semibold).monospacedDigit())
                    }
                }
            }
            .frame(maxWidth: 200)
            .padding(6)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 6))
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(Color.primary.opacity(0.12), lineWidth: 0.5)
            )
        }
    }

    private var noMatchingSeriesState: some View {
        VStack(spacing: 8) {
            Text("No matching series")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
            Text("This chart has no points for the current history window.")
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 24)
        .background(Color(NSColor.controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
    }

    private struct HoverItem {
        let label: String
        let seriesID: String
        let value: Double?
        let unit: String
    }

    private func nearestHoverPoints(at date: Date) -> [HoverItem] {
        let grouped = Dictionary(grouping: visiblePoints, by: \.seriesID)
        return summaries.compactMap { summary in
            guard let seriesPoints = grouped[summary.id],
                  let nearest = seriesPoints.min(by: {
                      abs($0.point.timestamp.timeIntervalSince(date)) < abs($1.point.timestamp.timeIntervalSince(date))
                  }) else { return nil }
            return HoverItem(
                label: summary.label,
                seriesID: summary.id,
                value: nearest.point.value,
                unit: nearest.point.unit
            )
        }
        .sorted { $0.label.localizedStandardCompare($1.label) == .orderedAscending }
    }

    private func formatHoverDate(_ date: Date) -> String {
        Self.hoverFormatters[selectedWindow]?.string(from: date) ?? ""
    }

    private func format(value: Double?, unit: String) -> String {
        guard let value else {
            return "-"
        }
        if unit == "%" {
            return "\(Int(value.rounded()))%"
        }
        if unit.isEmpty {
            return String(format: "%.2f", value)
        }
        return "\(String(format: "%.2f", value)) \(unit)"
    }

    private func seriesSwatch(for seriesID: String) -> some View {
        Canvas { ctx, size in
            var path = Path()
            path.move(to: CGPoint(x: 0, y: size.height / 2))
            path.addLine(to: CGPoint(x: size.width, y: size.height / 2))
            ctx.stroke(path, with: .color(seriesColor(for: seriesID)), style: lineStyle(for: seriesID))
        }
        .frame(width: 14, height: 3)
    }

    private func seriesColor(for seriesID: String) -> Color {
        seriesStyles[seriesID]?.color.swiftUIColor ?? ChartSeriesColor.blue.swiftUIColor
    }

    private func lineStyle(for seriesID: String) -> StrokeStyle {
        seriesStyles[seriesID]?.lineStyle.strokeStyle ?? ChartLineStyle.solid.strokeStyle
    }

    private static let hoverFormatters: [UsageHistoryTimeWindow: DateFormatter] = {
        UsageHistoryTimeWindow.allCases.reduce(into: [:]) { dict, window in
            let f = DateFormatter()
            switch window {
            case .sixHours, .twentyFourHours:
                f.dateFormat = "HH:mm"
            case .sevenDays:
                f.dateFormat = "MMM d, HH:mm"
            case .thirtyDays, .all:
                f.dateFormat = "MMM d"
            }
            dict[window] = f
        }
    }()
}

private struct ChartPoint: Identifiable {
    let seriesID: String
    let segmentID: String
    let point: UsageHistoryPoint

    var id: String {
        "\(seriesID)|\(point.timestamp.timeIntervalSince1970)|\(point.metricName)"
    }
}

private struct PlottedChartPoint: Identifiable {
    let chartPoint: ChartPoint
    let value: Double

    var id: String { chartPoint.id }
    var seriesID: String { chartPoint.seriesID }
    var segmentID: String { chartPoint.segmentID }
    var point: UsageHistoryPoint { chartPoint.point }
}
