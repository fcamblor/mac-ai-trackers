import Charts
import SwiftUI
import AIUsagesTrackersLib

struct UsageHistoryChartView: View {
    let snapshot: UsageHistorySnapshot
    let referenceDate: Date
    @Binding var selectedWindow: UsageHistoryTimeWindow
    let isLoading: Bool
    let onPreviousWindow: () -> Void
    let onNextWindow: () -> Void

    @State private var hiddenVendorIDs: Set<String> = []
    @State private var hiddenAccountIDs: Set<String> = []
    @State private var showWeeklyMetrics = true
    @State private var showNonWeeklyMetrics = true

    private var points: [UsageHistoryPoint] { snapshot.points }
    private var visiblePoints: [UsageHistoryPoint] {
        points.filter { point in
            !hiddenVendorIDs.contains(point.vendor.rawValue)
                && !hiddenAccountIDs.contains(point.account.rawValue)
                && (showWeeklyMetrics || !isWeekly(point.metricName))
                && (showNonWeeklyMetrics || isWeekly(point.metricName))
        }
    }

    private var summaries: [UsageHistorySeriesSummary] {
        let grouped = Dictionary(grouping: visiblePoints, by: \.seriesID)
        return grouped.compactMap { seriesID, points in
            guard let latest = points.max(by: { $0.timestamp < $1.timestamp }) else { return nil }
            return UsageHistorySeriesSummary(
                id: seriesID,
                label: latest.seriesLabel,
                latestValue: latest.value,
                unit: latest.unit,
                pointCount: points.count
            )
        }
        .sorted { $0.label.localizedStandardCompare($1.label) == .orderedAscending }
    }

    private var availableVendors: [String] {
        Array(Set(points.map(\.vendor.rawValue))).sorted {
            $0.localizedStandardCompare($1) == .orderedAscending
        }
    }

    private var availableAccounts: [String] {
        Array(Set(points.map(\.account.rawValue))).sorted {
            $0.localizedStandardCompare($1) == .orderedAscending
        }
    }

    private var seriesColors: [String: Color] {
        Dictionary(uniqueKeysWithValues: summaries.enumerated().map { index, summary in
            (summary.id, Self.palette[index % Self.palette.count])
        })
    }

    private var yAxisLabel: String {
        let units = Set(visiblePoints.map(\.unit).filter { !$0.isEmpty })
        if units.count == 1, let unit = units.first {
            return unit == "%" ? "Usage (%)" : "Usage (\(unit))"
        }
        return "Usage"
    }

    private var xDomain: ClosedRange<Date> {
        if let startDate = selectedWindow.startDate(relativeTo: referenceDate) {
            return startDate...referenceDate
        }

        guard let first = visiblePoints.first?.timestamp,
              let last = visiblePoints.last?.timestamp else {
            return referenceDate.addingTimeInterval(-60 * 60)...referenceDate
        }
        if first == last {
            return first.addingTimeInterval(-30 * 60)...last.addingTimeInterval(30 * 60)
        }
        return first...last
    }

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
            } else if visiblePoints.isEmpty {
                filteredEmptyState
            } else {
                chart
                summaryRows
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

            Menu {
                ForEach(availableVendors, id: \.self) { vendorID in
                    Button {
                        toggleVendor(vendorID)
                    } label: {
                        Label(vendorID, systemImage: hiddenVendorIDs.contains(vendorID) ? "circle" : "checkmark.circle.fill")
                    }
                }

                Divider()

                ForEach(availableAccounts, id: \.self) { accountID in
                    Button {
                        toggleAccount(accountID)
                    } label: {
                        Label(accountID, systemImage: hiddenAccountIDs.contains(accountID) ? "circle" : "checkmark.circle.fill")
                    }
                }

                Divider()

                Toggle("Weekly metrics", isOn: $showWeeklyMetrics)
                Toggle("Non-weekly metrics", isOn: $showNonWeeklyMetrics)
            } label: {
                Image(systemName: "line.3.horizontal.decrease.circle")
                .frame(width: 16, height: 16)
                .hoverAffordance()
            }
            .buttonStyle(.borderless)
            .controlSize(.small)
            .help("Filter chart series")
            .focusable(false)
        }
    }

    private var chart: some View {
        Chart(visiblePoints) { point in
            LineMark(
                x: .value("Time", point.timestamp),
                y: .value(yAxisLabel, point.value),
                series: .value("Metric", point.seriesLabel)
            )
            .interpolationMethod(.catmullRom)
            .foregroundStyle(seriesColor(for: point.seriesID))
        }
        .chartLegend(.hidden)
        .chartYAxisLabel(yAxisLabel)
        .chartXScale(domain: xDomain)
        .frame(height: 180)
        .padding(8)
        .background(Color(NSColor.controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(Color.primary.opacity(0.16), lineWidth: 1)
        )
    }

    private var summaryRows: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(summaries.prefix(6))) { summary in
                HStack(spacing: 8) {
                    RoundedRectangle(cornerRadius: 1)
                        .fill(seriesColor(for: summary.id))
                        .frame(width: 14, height: 3)

                    Text(summary.label)
                        .font(.system(size: 10))
                        .foregroundStyle(seriesColor(for: summary.id))
                        .lineLimit(1)
                        .truncationMode(.middle)

                    Spacer(minLength: 8)

                    Text(format(value: summary.latestValue, unit: summary.unit))
                        .font(.system(size: 10, weight: .semibold).monospacedDigit())
                }
            }
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

    private var filteredEmptyState: some View {
        VStack(spacing: 8) {
            Text("No visible series")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
            Text("Adjust the chart filters to show matching metrics.")
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

    private func format(value: Double, unit: String) -> String {
        if unit == "%" {
            return "\(Int(value.rounded()))%"
        }
        if unit.isEmpty {
            return String(format: "%.2f", value)
        }
        return "\(String(format: "%.2f", value)) \(unit)"
    }

    private func seriesColor(for seriesID: String) -> Color {
        seriesColors[seriesID] ?? Self.palette[0]
    }

    private func toggleVendor(_ vendorID: String) {
        if hiddenVendorIDs.contains(vendorID) {
            hiddenVendorIDs.remove(vendorID)
        } else {
            hiddenVendorIDs.insert(vendorID)
        }
    }

    private func toggleAccount(_ accountID: String) {
        if hiddenAccountIDs.contains(accountID) {
            hiddenAccountIDs.remove(accountID)
        } else {
            hiddenAccountIDs.insert(accountID)
        }
    }

    private func isWeekly(_ metricName: String) -> Bool {
        let lowercased = metricName.lowercased()
        return lowercased.contains("weekly")
            || lowercased.contains("(7d)")
            || lowercased.contains(" 7d")
            || lowercased.hasSuffix("7d")
    }

    private static let palette: [Color] = [
        Color(red: 0.20, green: 0.45, blue: 0.95),
        Color(red: 0.00, green: 0.56, blue: 0.44),
        Color(red: 0.88, green: 0.42, blue: 0.10),
        Color(red: 0.62, green: 0.34, blue: 0.88),
        Color(red: 0.86, green: 0.20, blue: 0.36),
        Color(red: 0.08, green: 0.55, blue: 0.72),
        Color(red: 0.54, green: 0.50, blue: 0.18),
        Color(red: 0.80, green: 0.30, blue: 0.70),
    ]
}
