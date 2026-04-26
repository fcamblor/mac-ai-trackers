import SwiftUI
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

private struct ChartSettingsContent: View {
    let preferences: UserDefaultsAppPreferences
    @Bindable var store: UsageStore

    @State private var pendingDelete: UUID?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            chartList
        }
        .confirmationDialog(
            deleteConfirmationTitle,
            isPresented: deleteConfirmationBinding,
            titleVisibility: .visible
        ) {
            Button("Delete chart", role: .destructive) {
                if let id = pendingDelete {
                    delete(configurationID: id)
                }
                pendingDelete = nil
            }
            Button("Cancel", role: .cancel) {
                pendingDelete = nil
            }
        } message: {
            Text("This chart will no longer appear in the popover.")
        }
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 3) {
                Text("Charts")
                    .font(.headline)
                Text("Configure the charts shown in the history tab.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button {
                addConfiguration()
            } label: {
                Label("Add", systemImage: "plus")
            }
        }
        .padding(16)
    }

    @ViewBuilder
    private var chartList: some View {
        if preferences.chartConfigurations.isEmpty {
            emptyState
        } else {
            ScrollView {
                VStack(spacing: 0) {
                    ForEach(Array(preferences.chartConfigurations.enumerated()), id: \.element.id) { index, _ in
                        ChartConfigurationCard(
                            preferences: preferences,
                            store: store,
                            index: index,
                            canMoveUp: index > 0,
                            canMoveDown: index < preferences.chartConfigurations.count - 1,
                            onMoveUp: { move(from: index, to: index - 1) },
                            onMoveDown: { move(from: index, to: index + 2) },
                            onRequestDelete: { pendingDelete = preferences.chartConfigurations[index].id }
                        )
                        Divider()
                    }
                }
                .padding(.horizontal, 16)
            }
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

    private func addConfiguration() {
        preferences.chartConfigurations.append(ChartConfigurationsSeeder.defaultConfigurations()[0])
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

private struct ChartConfigurationCard: View {
    let preferences: UserDefaultsAppPreferences
    @Bindable var store: UsageStore
    let index: Int
    let canMoveUp: Bool
    let canMoveDown: Bool
    let onMoveUp: () -> Void
    let onMoveDown: () -> Void
    let onRequestDelete: () -> Void

    @State private var isExpanded = false

    private var configurationBinding: Binding<ChartConfiguration>? {
        guard preferences.chartConfigurations.indices.contains(index) else { return nil }
        return Binding(
            get: { preferences.chartConfigurations[index] },
            set: { preferences.chartConfigurations[index] = $0 }
        )
    }

    var body: some View {
        if let configurationBinding {
            DisclosureGroup(isExpanded: $isExpanded) {
                ChartConfigurationEditor(
                    store: store,
                    configuration: configurationBinding
                )
                .padding(.top, 8)
            } label: {
                header(for: configurationBinding.wrappedValue)
            }
            .padding(.vertical, 4)
        }
    }

    private func header(for configuration: ChartConfiguration) -> some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(configuration.title)
                    .font(.body)
                    .lineLimit(1)
                Text(summary(for: configuration))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            HStack(spacing: 4) {
                Button(action: onMoveUp) {
                    Image(systemName: "arrow.up")
                }
                .buttonStyle(.borderless)
                .disabled(!canMoveUp)
                .help("Move up")

                Button(action: onMoveDown) {
                    Image(systemName: "arrow.down")
                }
                .buttonStyle(.borderless)
                .disabled(!canMoveDown)
                .help("Move down")

                Button(action: onRequestDelete) {
                    Image(systemName: "trash")
                        .foregroundStyle(.red)
                }
                .buttonStyle(.borderless)
                .help("Delete chart")
            }
        }
    }

    private func summary(for configuration: ChartConfiguration) -> String {
        switch configuration.selection {
        case .allAvailable:
            return "All available metrics"
        case .custom(let series):
            return "\(series.count) custom series"
        }
    }
}

private struct ChartConfigurationEditor: View {
    @Bindable var store: UsageStore
    @Binding var configuration: ChartConfiguration

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Name")
                    .frame(width: 80, alignment: .leading)
                TextField("", text: $configuration.title)
                    .textFieldStyle(.roundedBorder)
            }

            Picker("Series", selection: selectionModeBinding) {
                Text("All available metrics").tag(ChartSelectionMode.allAvailable)
                Text("Custom").tag(ChartSelectionMode.custom)
            }
            .pickerStyle(.segmented)

            if case .custom = configuration.selection {
                customSeriesList
            }
        }
    }

    private var customSeriesList: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Series")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textCase(.uppercase)
                Spacer()
                Button {
                    addSeries()
                } label: {
                    Label("Add series", systemImage: "plus")
                }
                .disabled(availableVendors.isEmpty)
            }

            let series = customSeries
            if series.isEmpty {
                Text("No custom series configured")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 6)
            } else {
                ForEach(Array(series.enumerated()), id: \.element.id) { index, _ in
                    ChartSeriesEditor(
                        store: store,
                        series: customSeriesBinding(at: index),
                        onDelete: { deleteSeries(at: index) }
                    )
                    .padding(10)
                    .background(Color(NSColor.controlBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
                }
            }
        }
    }

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

    private func customSeriesBinding(at index: Int) -> Binding<ChartSeriesConfig> {
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

    private func deleteSeries(at index: Int) {
        var series = customSeries
        guard series.indices.contains(index) else { return }
        series.remove(at: index)
        configuration.selection = .custom(series)
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

private struct ChartSeriesEditor: View {
    @Bindable var store: UsageStore
    @Binding var series: ChartSeriesConfig
    let onDelete: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Series name")
                    .frame(width: 80, alignment: .leading)
                TextField("", text: seriesLabelBinding)
                    .textFieldStyle(.roundedBorder)
            }

            HStack(alignment: .top) {
                MetricSelectionEditor(
                    store: store,
                    vendor: $series.vendor,
                    account: $series.account,
                    metricName: $series.metricName
                )

                Spacer(minLength: 8)

                Button(action: onDelete) {
                    Image(systemName: "trash")
                        .foregroundStyle(.red)
                }
                .buttonStyle(.borderless)
                .help("Delete series")
            }

            HStack {
                Text("Style")
                    .frame(width: 80, alignment: .leading)

                Picker("Color", selection: $series.style.color) {
                    ForEach(ChartSeriesColor.allCases) { color in
                        HStack(spacing: 6) {
                            Circle()
                                .fill(color.swiftUIColor)
                                .frame(width: 10, height: 10)
                            Text(color.displayName)
                        }
                        .tag(color)
                    }
                }
                .labelsHidden()
                .frame(width: 120)

                Picker("Line", selection: $series.style.lineStyle) {
                    ForEach(ChartLineStyle.allCases) { lineStyle in
                        Text(lineStyle.displayName).tag(lineStyle)
                    }
                }
                .labelsHidden()
                .frame(width: 120)
            }
        }
    }

    private var seriesLabelBinding: Binding<String> {
        Binding(
            get: {
                let customLabel = series.label.trimmingCharacters(in: .whitespacesAndNewlines)
                return customLabel.isEmpty ? defaultSeriesLabel : series.label
            },
            set: { series.label = $0 }
        )
    }

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

private enum ChartSelectionMode: Hashable {
    case allAvailable
    case custom
}
