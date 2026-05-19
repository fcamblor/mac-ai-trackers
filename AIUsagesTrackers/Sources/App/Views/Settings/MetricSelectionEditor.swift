import SwiftUI
import Foundation
import AIUsagesTrackersLib

struct MetricSelectionOptions: Equatable {
    private let entriesByVendor: [Vendor: [VendorUsageEntry]]
    private let signature: Int

    init(entries: [VendorUsageEntry]) {
        let shouldLogPerformance = Loggers.app.effectiveMinLevel <= .debug
        let startedAt = shouldLogPerformance ? DispatchTime.now().uptimeNanoseconds : 0
        entriesByVendor = Dictionary(grouping: entries, by: \.vendor)
        var hasher = Hasher()
        var metricCount = 0
        for entry in entries.sorted(by: { $0.id < $1.id }) {
            hasher.combine(entry.vendor)
            hasher.combine(entry.account)
            hasher.combine(entry.isActive)
            for metric in entry.metrics {
                if shouldLogPerformance {
                    metricCount += 1
                }
                hasher.combine(SegmentEditingHelpers.metricName(metric))
            }
        }
        signature = hasher.finalize()
        if shouldLogPerformance {
            let elapsedMillis = Double(DispatchTime.now().uptimeNanoseconds - startedAt) / 1_000_000
            let elapsed = String(format: "%.2f", elapsedMillis)
            Loggers.app.log(
                .debug,
                "ChartSettingsPerf: MetricSelectionOptions built entries=\(entries.count) "
                    + "vendors=\(entriesByVendor.count) metrics=\(metricCount) elapsedMs=\(elapsed)"
            )
        }
    }

    static func == (lhs: MetricSelectionOptions, rhs: MetricSelectionOptions) -> Bool {
        lhs.signature == rhs.signature
    }

    var availableVendors: [Vendor] {
        entriesByVendor.keys.sorted { $0.rawValue < $1.rawValue }
    }

    func availableAccounts(for vendor: Vendor) -> [AccountEmail] {
        entriesByVendor[vendor, default: []]
            .filter { !$0.metrics.isEmpty }
            .map(\.account)
    }

    func availableMetrics(vendor: Vendor, account: AccountSelection) -> [MetricOption] {
        guard let entry = resolveEntry(vendor: vendor, account: account) else { return [] }
        return entry.metrics.compactMap { metric in
            guard let name = SegmentEditingHelpers.metricName(metric) else { return nil }
            return MetricOption(name: name, kind: metric.kind)
        }
    }

    func selectedMetric(
        vendor: Vendor,
        account: AccountSelection,
        metricName: String
    ) -> UsageMetric? {
        resolveEntry(vendor: vendor, account: account)?
            .metrics
            .first { SegmentEditingHelpers.metricName($0) == metricName }
    }

    func firstMetricName(vendor: Vendor, account: AccountSelection) -> String? {
        resolveEntry(vendor: vendor, account: account)?
            .metrics
            .compactMap(SegmentEditingHelpers.metricName)
            .first
    }

    func metricExists(on vendor: Vendor, account: AccountSelection, name: String) -> Bool {
        guard let entry = resolveEntry(vendor: vendor, account: account) else { return false }
        return entry.metrics.contains { SegmentEditingHelpers.metricName($0) == name }
    }

    func resolveEntry(vendor: Vendor, account: AccountSelection) -> VendorUsageEntry? {
        let vendorEntries = entriesByVendor[vendor, default: []]
        switch account {
        case .currentlyActive:
            return vendorEntries.first(where: { $0.isActive })
        case .specific(let email):
            return vendorEntries.first(where: { $0.account == email })
        }
    }
}

struct MetricOption: Hashable {
    let name: String
    let kind: MetricKind
}

struct MetricSelectionEditor: View {
    enum Layout {
        /// Original look: label on the left, picker on the right, stacked vertically.
        case stacked
        /// Vendor + Account on a single row, Metric full-width below; no fixed
        /// left labels — each picker carries its own small caption above it.
        case grid
    }

    @Bindable var store: UsageStore
    @Binding var vendor: Vendor
    @Binding var account: AccountSelection
    @Binding var metricName: String

    let labelWidth: CGFloat
    let layout: Layout
    let options: MetricSelectionOptions?
    let onMetricChanged: (UsageMetric?) -> Void

    init(
        store: UsageStore,
        vendor: Binding<Vendor>,
        account: Binding<AccountSelection>,
        metricName: Binding<String>,
        labelWidth: CGFloat = 80,
        layout: Layout = .stacked,
        options: MetricSelectionOptions? = nil,
        onMetricChanged: @escaping (UsageMetric?) -> Void = { _ in }
    ) {
        self.store = store
        self._vendor = vendor
        self._account = account
        self._metricName = metricName
        self.labelWidth = labelWidth
        self.layout = layout
        self.options = options
        self.onMetricChanged = onMetricChanged
    }

    var body: some View {
        switch layout {
        case .stacked:
            VStack(alignment: .leading, spacing: 12) {
                vendorPicker
                accountPicker
                metricPicker
            }
        case .grid:
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .top, spacing: 12) {
                    captionedPicker("Vendor") { vendorPickerControl }
                    captionedPicker("Account") { accountPickerControl }
                }
                captionedPicker("Metric") { metricPickerControl }
            }
        }
    }

    // MARK: Grid pieces

    private func captionedPicker<Content: View>(
        _ caption: String,
        @ViewBuilder _ content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(caption)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
                .tracking(0.4)
            content()
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var vendorPickerControl: some View {
        Picker("", selection: Binding(
            get: { vendor },
            set: { newVendor in
                vendor = newVendor
                account = .currentlyActive
                metricName = firstMetricName(vendor: newVendor, account: account) ?? ""
                onMetricChanged(selectedMetric(vendor: vendor, account: account, metricName: metricName))
            }
        )) {
            ForEach(availableVendors, id: \.rawValue) { v in
                Text(VendorBrandingResolver.displayName(for: v)).tag(v)
            }
        }
        .labelsHidden()
        .pickerStyle(.menu)
    }

    private var accountPickerControl: some View {
        Picker("", selection: Binding(
            get: { account },
            set: { newAccount in
                account = newAccount
                if firstMetricName(vendor: vendor, account: newAccount) == nil {
                    onMetricChanged(nil)
                } else if !metricExists(on: vendor, account: newAccount, name: metricName) {
                    metricName = firstMetricName(vendor: vendor, account: newAccount) ?? ""
                    onMetricChanged(selectedMetric(vendor: vendor, account: newAccount, metricName: metricName))
                }
            }
        )) {
            Text("Currently active account").tag(AccountSelection.currentlyActive)
            Divider()
            ForEach(availableAccounts(for: vendor), id: \.rawValue) { email in
                Text(email.rawValue).tag(AccountSelection.specific(email))
            }
        }
        .labelsHidden()
    }

    @ViewBuilder
    private var metricPickerControl: some View {
        let metrics = availableMetrics(vendor: vendor, account: account)
        if metrics.isEmpty {
            Text("No metrics available")
                .foregroundStyle(.secondary)
                .font(.caption)
        } else {
            Picker("", selection: Binding(
                get: { metricName },
                set: { newName in
                    metricName = newName
                    onMetricChanged(selectedMetric(vendor: vendor, account: account, metricName: newName))
                }
            )) {
                ForEach(metrics, id: \.name) { option in
                    Text(option.name).tag(option.name)
                }
            }
            .labelsHidden()
        }
    }

    // MARK: Stacked rows (unchanged behavior)

    private var vendorPicker: some View {
        HStack {
            Text("Vendor")
                .frame(width: labelWidth, alignment: .leading)
            Picker("", selection: Binding(
                get: { vendor },
                set: { newVendor in
                    vendor = newVendor
                    account = .currentlyActive
                    metricName = firstMetricName(vendor: newVendor, account: account) ?? ""
                    onMetricChanged(selectedMetric(vendor: vendor, account: account, metricName: metricName))
                }
            )) {
                ForEach(availableVendors, id: \.rawValue) { vendor in
                    Text(VendorBrandingResolver.displayName(for: vendor)).tag(vendor)
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
        }
    }

    private var accountPicker: some View {
        HStack {
            Text("Account")
                .frame(width: labelWidth, alignment: .leading)
            Picker("", selection: Binding(
                get: { account },
                set: { newAccount in
                    account = newAccount
                    if firstMetricName(vendor: vendor, account: newAccount) == nil {
                        onMetricChanged(nil)
                    } else if !metricExists(on: vendor, account: newAccount, name: metricName) {
                        metricName = firstMetricName(vendor: vendor, account: newAccount) ?? ""
                        onMetricChanged(selectedMetric(vendor: vendor, account: newAccount, metricName: metricName))
                    }
                }
            )) {
                Text("Currently active account").tag(AccountSelection.currentlyActive)
                Divider()
                ForEach(availableAccounts(for: vendor), id: \.rawValue) { email in
                    Text(email.rawValue).tag(AccountSelection.specific(email))
                }
            }
            .labelsHidden()
        }
    }

    private var metricPicker: some View {
        let metrics = availableMetrics(vendor: vendor, account: account)
        return HStack {
            Text("Metric")
                .frame(width: labelWidth, alignment: .leading)
            if metrics.isEmpty {
                Text("No metrics available")
                    .foregroundStyle(.secondary)
                    .font(.caption)
            } else {
                Picker("", selection: Binding(
                    get: { metricName },
                    set: { newName in
                        metricName = newName
                        onMetricChanged(selectedMetric(vendor: vendor, account: account, metricName: newName))
                    }
                )) {
                    ForEach(metrics, id: \.name) { option in
                        Text(option.name).tag(option.name)
                    }
                }
                .labelsHidden()
            }
        }
    }

    // MARK: - Data helpers

    private var resolvedOptions: MetricSelectionOptions {
        options ?? MetricSelectionOptions(entries: store.entries)
    }

    private var availableVendors: [Vendor] {
        resolvedOptions.availableVendors
    }

    private func availableAccounts(for vendor: Vendor) -> [AccountEmail] {
        resolvedOptions.availableAccounts(for: vendor)
    }

    private func availableMetrics(vendor: Vendor, account: AccountSelection) -> [MetricOption] {
        resolvedOptions.availableMetrics(vendor: vendor, account: account)
    }

    private func firstMetricName(vendor: Vendor, account: AccountSelection) -> String? {
        resolvedOptions.firstMetricName(vendor: vendor, account: account)
    }

    private func metricExists(on vendor: Vendor, account: AccountSelection, name: String) -> Bool {
        resolvedOptions.metricExists(on: vendor, account: account, name: name)
    }

    private func selectedMetric(
        vendor: Vendor,
        account: AccountSelection,
        metricName: String
    ) -> UsageMetric? {
        resolvedOptions.selectedMetric(vendor: vendor, account: account, metricName: metricName)
    }
}
