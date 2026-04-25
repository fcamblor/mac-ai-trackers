import SwiftUI
import AppKit
import AIUsagesTrackersLib

struct MenubarHintSettingsView: View {
    let preferences: any AppPreferences

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        if let store = AppDelegate.sharedStore {
            MenubarHintContent(
                preferences: preferences,
                store: store,
                isDark: colorScheme == .dark
            )
        } else {
            ContentUnavailableView(
                "Settings loading",
                systemImage: "hourglass",
                description: Text("Usage data is initializing. Close and reopen Settings.")
            )
        }
    }
}

// MARK: - Content

private struct MenubarHintContent: View {
    let preferences: any AppPreferences
    @Bindable var store: UsageStore
    let isDark: Bool

    @State private var pendingDelete: UUID?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            previewPanel
            Divider()
            segmentsPanel
        }
        .confirmationDialog(
            deleteConfirmationTitle,
            isPresented: deleteConfirmationBinding,
            titleVisibility: .visible
        ) {
            Button("Delete segment", role: .destructive) {
                if let id = pendingDelete {
                    delete(segmentID: id)
                }
                pendingDelete = nil
            }
            Button("Cancel", role: .cancel) {
                pendingDelete = nil
            }
        } message: {
            Text("This segment will no longer appear in the menu bar.")
        }
    }

    // MARK: Preview

    @ViewBuilder
    private var previewPanel: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Preview")
                .font(.caption)
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
            HStack {
                Image(nsImage: MenuBarLabelRenderer.render(
                    segments: store.menuBarSegments,
                    separator: preferences.menuBarSeparator,
                    fallbackText: store.menuBarText,
                    isDarkMenuBar: isDark
                ))
                Spacer()
            }
            .padding(8)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(isDark ? Color.black.opacity(0.6) : Color.white)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .stroke(Color.secondary.opacity(0.3), lineWidth: 1)
            )

            HStack(spacing: 6) {
                Text("Separator")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                TextField("", text: Binding(
                    get: { preferences.menuBarSeparator },
                    set: { preferences.menuBarSeparator = $0 }
                ))
                .textFieldStyle(.roundedBorder)
                .frame(width: 80)
            }
        }
        .padding(16)
    }

    // MARK: Segments list

    @ViewBuilder
    private var segmentsPanel: some View {
        if AppDelegate.sharedPreferences.menuBarSegments.isEmpty {
            emptyState
        } else {
            segmentsList
        }
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Spacer(minLength: 24)
            Text("No segments configured")
                .font(.headline)
            Text("The menu bar will show \"--\" until you add a segment.")
                .font(.caption)
                .foregroundStyle(.secondary)
            Button {
                addSegment()
            } label: {
                Label("Add your first segment", systemImage: "plus")
            }
            .disabled(availableVendors.isEmpty)
            Spacer(minLength: 24)
        }
        .frame(maxWidth: .infinity)
        .padding(16)
    }

    private var segmentsList: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Segments")
                    .font(.headline)
                Spacer()
                Button {
                    addSegment()
                } label: {
                    Label("Add", systemImage: "plus")
                }
                .disabled(availableVendors.isEmpty)
            }
            .padding(.horizontal, 16)
            .padding(.top, 12)
            .padding(.bottom, 4)

            ScrollView {
                VStack(spacing: 0) {
                    ForEach(Array(AppDelegate.sharedPreferences.menuBarSegments.enumerated()), id: \.element.id) { index, _ in
                        SegmentCardView(
                            preferences: preferences,
                            store: store,
                            isDark: isDark,
                            index: index,
                            canMoveUp: index > 0,
                            canMoveDown: index < AppDelegate.sharedPreferences.menuBarSegments.count - 1,
                            onMoveUp: { move(from: index, to: index - 1) },
                            onMoveDown: { move(from: index, to: index + 2) },
                            onRequestDelete: { pendingDelete = AppDelegate.sharedPreferences.menuBarSegments[index].id }
                        )
                        Divider()
                    }
                }
                .padding(.horizontal, 16)
            }
        }
    }

    // MARK: Mutations

    private func addSegment() {
        let prefs = AppDelegate.sharedPreferences
        guard let vendor = availableVendors.first else { return }
        let defaultMetricName = firstAvailableMetricName(for: vendor, account: .currentlyActive)
            ?? ""
        let display: SegmentDisplay = makeDefaultDisplay(
            vendor: vendor,
            account: .currentlyActive,
            metricName: defaultMetricName
        )
        let new = MenuBarSegmentConfig(
            vendor: vendor,
            account: .currentlyActive,
            metricName: defaultMetricName,
            display: display
        )
        prefs.menuBarSegments.append(new)
    }

    private func delete(segmentID: UUID) {
        let prefs = AppDelegate.sharedPreferences
        prefs.menuBarSegments.removeAll { $0.id == segmentID }
    }

    private func move(from source: Int, to destination: Int) {
        let prefs = AppDelegate.sharedPreferences
        var segments = prefs.menuBarSegments
        guard source >= 0, source < segments.count else { return }
        let dest = max(0, min(destination, segments.count))
        segments.move(fromOffsets: IndexSet(integer: source), toOffset: dest)
        prefs.menuBarSegments = segments
    }

    // MARK: Helpers

    private var availableVendors: [Vendor] {
        Array(Set(store.entries.map(\.vendor))).sorted { $0.rawValue < $1.rawValue }
    }

    private func firstAvailableMetricName(
        for vendor: Vendor,
        account: AccountSelection
    ) -> String? {
        let entry = resolveEntry(vendor: vendor, account: account, in: store.entries)
        return entry?.metrics.compactMap(metricName).first
    }

    private func makeDefaultDisplay(
        vendor: Vendor,
        account: AccountSelection,
        metricName: String
    ) -> SegmentDisplay {
        let entry = resolveEntry(vendor: vendor, account: account, in: store.entries)
        let metric = entry?.metrics.first(where: { SegmentEditingHelpers.metricName($0) == metricName })
        switch metric {
        case .some(.payAsYouGo):
            return .payAsYouGo
        case .some(.timeWindow), .some(.unknown), .none:
            return .timeWindow(TimeWindowDisplay(letter: MenuBarMetricLetter.defaultLetter(for: metricName)))
        }
    }

    private func resolveEntry(
        vendor: Vendor,
        account: AccountSelection,
        in entries: [VendorUsageEntry]
    ) -> VendorUsageEntry? {
        let vendorEntries = entries.filter { $0.vendor == vendor }
        switch account {
        case .currentlyActive:
            return vendorEntries.first(where: { $0.isActive })
        case .specific(let email):
            return vendorEntries.first(where: { $0.account == email })
        }
    }

    private func metricName(_ metric: UsageMetric) -> String? {
        SegmentEditingHelpers.metricName(metric)
    }

    private var deleteConfirmationBinding: Binding<Bool> {
        Binding(
            get: { pendingDelete != nil },
            set: { if !$0 { pendingDelete = nil } }
        )
    }

    private var deleteConfirmationTitle: String {
        guard let id = pendingDelete,
              let segment = AppDelegate.sharedPreferences.menuBarSegments.first(where: { $0.id == id }) else {
            return "Delete segment?"
        }
        return "Delete \(segment.metricName) segment?"
    }
}

// MARK: - Shared helpers

enum SegmentEditingHelpers {
    static func metricName(_ metric: UsageMetric) -> String? {
        switch metric {
        case .timeWindow(let name, _, _, _):   return name
        case .payAsYouGo(let name, _, _):      return name
        case .unknown:                         return nil
        }
    }

    static func metricKind(_ metric: UsageMetric) -> MetricKind {
        metric.kind
    }
}
