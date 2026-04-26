import SwiftUI
import AIUsagesTrackersLib

/// Scrollable popover anchored to the menu bar item; uses LazyVStack + maxHeight
/// so the popover does not stretch unboundedly when many accounts are present.
struct UsageDetailsView: View {
    let store: UsageStore
    let refreshState: RefreshState
    let historyReader: UsageHistoryReader
    let onRefresh: () async -> Void
    let onOpenSettings: () -> Void
    let onQuit: () -> Void

    @State private var contentMode: PopoverContentMode = .list
    @State private var selectedHistoryWindow: UsageHistoryTimeWindow = .twentyFourHours
    @State private var historySnapshot: UsageHistorySnapshot = .empty
    @State private var historyReferenceDate = Date()
    @State private var historyWindowEndDate: Date?
    @State private var isLoadingHistory = false

    private static let popoverWidth: CGFloat = 320
    private static let maxScreenHeightRatio: CGFloat = 0.9
    private static let fallbackScreenHeight: CGFloat = 800
    private static let historyAutoRefreshInterval: Duration = .seconds(60)
    /// Reserved for header + footer + dividers so the full popover stays within the ratio cap.
    private static let chromeHeightReserve: CGFloat = 80

    private var maxScrollHeight: CGFloat {
        let screenHeight = NSScreen.main?.visibleFrame.height ?? Self.fallbackScreenHeight
        return screenHeight * Self.maxScreenHeightRatio - Self.chromeHeightReserve
    }

    var body: some View {
        VStack(spacing: 0) {
            header

            Divider()

            content

            Divider()

            footer
        }
        .frame(width: Self.popoverWidth)
        .task(id: historyTaskID) {
            await runHistoryRefreshLoopIfNeeded()
        }
    }

    private var historyTaskID: String {
        "\(contentMode.rawValue)-\(selectedHistoryWindow.rawValue)"
    }

    /// Returns a map of vendor → first index in sorted, for vendors that have active outages.
    private func vendorsNeedingBanner(in sorted: [VendorUsageEntry]) -> [Vendor: Int] {
        var result: [Vendor: Int] = [:]
        for (index, entry) in sorted.enumerated() where result[entry.vendor] == nil {
            if store.outagesByVendor[entry.vendor] != nil {
                result[entry.vendor] = index
            }
        }
        return result
    }

    // MARK: - Subviews

    @ViewBuilder
    private var content: some View {
        switch contentMode {
        case .list:
            listingContent
        case .chart:
            chartContent
        }
    }

    @ViewBuilder
    private var listingContent: some View {
        let sorted = store.entries.sortedForDisplay()
        if sorted.isEmpty {
            emptyState
        } else {
            ScrollView {
                LazyVStack(spacing: 8) {
                    // Track which vendors have already shown their status banner
                    // using a running cursor — entries are sorted by vendor so
                    // entries of the same vendor are contiguous.
                    let vendorsWithBanner = vendorsNeedingBanner(in: sorted)
                    ForEach(Array(sorted.enumerated()), id: \.element.id) { index, entry in
                        if vendorsWithBanner[entry.vendor] == index,
                           let outages = store.outagesByVendor[entry.vendor] {
                            VendorStatusBanner(outages: outages)
                        }
                        AccountCardView(
                            entry: entry,
                            isRefreshing: refreshState.isRefreshing(
                                vendor: entry.vendor,
                                account: entry.account
                            )
                        )
                    }
                }
                .padding(12)
            }
            .frame(maxHeight: maxScrollHeight)
            .background(Color(NSColor.windowBackgroundColor).opacity(0.4))
        }
    }

    private var chartContent: some View {
        ScrollView {
            UsageHistoryChartView(
                snapshot: historySnapshot,
                referenceDate: historyReferenceDate,
                selectedWindow: historyWindowBinding,
                isLoading: isLoadingHistory,
                onPreviousWindow: {
                    Task { await moveHistoryWindow(direction: .previous) }
                },
                onNextWindow: {
                    Task { await moveHistoryWindow(direction: .next) }
                }
            )
        }
        .frame(maxHeight: maxScrollHeight)
        .background(Color(NSColor.windowBackgroundColor).opacity(0.4))
    }

    private var historyWindowBinding: Binding<UsageHistoryTimeWindow> {
        Binding(
            get: { selectedHistoryWindow },
            set: { newValue in
                selectedHistoryWindow = newValue
                historyWindowEndDate = nil
            }
        )
    }

    private var header: some View {
        let refreshing = !refreshState.inFlight.isEmpty
        return HStack(spacing: 8) {
            Button {
                onOpenSettings()
            } label: {
                Image(systemName: "gearshape")
                    .frame(width: 16, height: 16)
                    .hoverAffordance()
            }
            .buttonStyle(.borderless)
            .controlSize(.small)
            .help("Settings")
            .keyboardShortcut(",", modifiers: .command)
            .focusable(false)

            Spacer()

            Text("AI Usages Tracker")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)

            Spacer()

            Button {
                guard !refreshing else { return }
                Task { await onRefresh() }
            } label: {
                ZStack {
                    if refreshing {
                        ProgressView()
                            .controlSize(.small)
                            .scaleEffect(0.6)
                    } else {
                        Image(systemName: "arrow.clockwise")
                    }
                }
                .frame(width: 16, height: 16)
                .hoverAffordance(isEnabled: !refreshing)
            }
            .buttonStyle(.borderless)
            .controlSize(.small)
            .disabled(refreshing)
            .help("Refresh usage data")
            .keyboardShortcut("r")
            .focusable(false)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Text("No usage data")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
            Text("Waiting for data...")
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 32)
    }

    private var footer: some View {
        HStack {
            Picker("Popover content", selection: $contentMode) {
                Image(systemName: "list.bullet")
                    .tag(PopoverContentMode.list)
                Image(systemName: "chart.xyaxis.line")
                    .tag(PopoverContentMode.chart)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .controlSize(.mini)
            .frame(width: 62)
            .help("Switch between usage list and history chart")
            .focusable(false)

            Spacer()

            Button {
                onQuit()
            } label: {
                Text("Quit")
                    .hoverAffordance()
            }
            .buttonStyle(.borderless)
            .keyboardShortcut("q")
            .controlSize(.small)
            .focusable(false)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    @MainActor
    private func runHistoryRefreshLoopIfNeeded() async {
        guard contentMode == .chart else { return }
        while !Task.isCancelled {
            await loadHistory()
            do {
                try await Task.sleep(for: Self.historyAutoRefreshInterval)
            } catch {
                break
            }
        }
    }

    @MainActor
    private func loadHistory() async {
        let requestedWindow = selectedHistoryWindow
        let requestedEndDate = historyWindowEndDate
        let requestedDate = requestedEndDate ?? Date()
        isLoadingHistory = true
        let snapshot = await historyReader.load(window: requestedWindow, now: requestedDate)
        guard contentMode == .chart,
              selectedHistoryWindow == requestedWindow,
              historyWindowEndDate == requestedEndDate else {
            isLoadingHistory = false
            return
        }
        historySnapshot = snapshot
        historyReferenceDate = requestedDate
        isLoadingHistory = false
    }

    @MainActor
    private func moveHistoryWindow(direction: HistoryWindowDirection) async {
        guard let interval = selectedHistoryWindow.timeInterval else { return }
        let currentEndDate = historyReferenceDate
        let targetEndDate: Date
        switch direction {
        case .previous:
            targetEndDate = currentEndDate.addingTimeInterval(-interval)
        case .next:
            targetEndDate = min(currentEndDate.addingTimeInterval(interval), Date())
        }
        guard targetEndDate != currentEndDate else { return }
        historyWindowEndDate = targetEndDate
        await loadHistory()
    }
}

private enum PopoverContentMode: String, Hashable {
    case list
    case chart
}

private enum HistoryWindowDirection {
    case previous
    case next
}
