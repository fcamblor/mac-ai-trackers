import SwiftUI
import AIUsagesTrackersLib

struct MetricSelectionEditor: View {
    @Bindable var store: UsageStore
    @Binding var vendor: Vendor
    @Binding var account: AccountSelection
    @Binding var metricName: String

    let labelWidth: CGFloat
    let onMetricChanged: (UsageMetric?) -> Void

    init(
        store: UsageStore,
        vendor: Binding<Vendor>,
        account: Binding<AccountSelection>,
        metricName: Binding<String>,
        labelWidth: CGFloat = 80,
        onMetricChanged: @escaping (UsageMetric?) -> Void = { _ in }
    ) {
        self.store = store
        self._vendor = vendor
        self._account = account
        self._metricName = metricName
        self.labelWidth = labelWidth
        self.onMetricChanged = onMetricChanged
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            vendorPicker
            accountPicker
            metricPicker
        }
    }

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
                    Text(VendorBranding.displayName(for: vendor)).tag(vendor)
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

    private var availableVendors: [Vendor] {
        Array(Set(store.entries.map(\.vendor))).sorted { $0.rawValue < $1.rawValue }
    }

    private func availableAccounts(for vendor: Vendor) -> [AccountEmail] {
        store.entries
            .filter { $0.vendor == vendor && !$0.metrics.isEmpty }
            .map(\.account)
    }

    private struct MetricOption: Hashable {
        let name: String
        let kind: MetricKind
    }

    private func availableMetrics(vendor: Vendor, account: AccountSelection) -> [MetricOption] {
        guard let entry = resolveEntry(vendor: vendor, account: account) else { return [] }
        return entry.metrics.compactMap { metric in
            guard let name = SegmentEditingHelpers.metricName(metric) else { return nil }
            return MetricOption(name: name, kind: metric.kind)
        }
    }

    private func resolveEntry(vendor: Vendor, account: AccountSelection) -> VendorUsageEntry? {
        let vendorEntries = store.entries.filter { $0.vendor == vendor }
        switch account {
        case .currentlyActive:
            return vendorEntries.first(where: { $0.isActive })
        case .specific(let email):
            return vendorEntries.first(where: { $0.account == email })
        }
    }

    private func firstMetricName(vendor: Vendor, account: AccountSelection) -> String? {
        resolveEntry(vendor: vendor, account: account)?
            .metrics
            .compactMap(SegmentEditingHelpers.metricName)
            .first
    }

    private func metricExists(on vendor: Vendor, account: AccountSelection, name: String) -> Bool {
        guard let entry = resolveEntry(vendor: vendor, account: account) else { return false }
        return entry.metrics.contains { SegmentEditingHelpers.metricName($0) == name }
    }

    private func selectedMetric(
        vendor: Vendor,
        account: AccountSelection,
        metricName: String
    ) -> UsageMetric? {
        resolveEntry(vendor: vendor, account: account)?
            .metrics
            .first { SegmentEditingHelpers.metricName($0) == metricName }
    }
}
