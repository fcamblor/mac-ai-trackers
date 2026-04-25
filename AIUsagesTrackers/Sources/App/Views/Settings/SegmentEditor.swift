import SwiftUI
import AIUsagesTrackersLib

struct SegmentEditor: View {
    let preferences: any AppPreferences
    @Bindable var store: UsageStore
    let index: Int

    private var segmentBinding: Binding<MenuBarSegmentConfig>? {
        guard preferences.menuBarSegments.indices.contains(index) else { return nil }
        return Binding(
            get: { preferences.menuBarSegments[index] },
            set: { preferences.menuBarSegments[index] = $0 }
        )
    }

    var body: some View {
        if let segmentBinding {
            VStack(alignment: .leading, spacing: 12) {
                vendorPicker(segmentBinding)
                accountPicker(segmentBinding)
                metricPicker(segmentBinding)

                Divider()

                switch segmentBinding.wrappedValue.display {
                case .timeWindow:
                    timeWindowEditor(segmentBinding)
                case .payAsYouGo:
                    payAsYouGoInfo(segmentBinding)
                }
            }
        }
    }

    // MARK: Vendor

    private func vendorPicker(_ binding: Binding<MenuBarSegmentConfig>) -> some View {
        let vendors = availableVendors
        return HStack {
            Text("Vendor")
                .frame(width: 80, alignment: .leading)
            Picker("", selection: Binding(
                get: { binding.wrappedValue.vendor },
                set: { newVendor in
                    var seg = binding.wrappedValue
                    seg.vendor = newVendor
                    // Reset account + metric to first valid couple for the new vendor
                    seg.account = .currentlyActive
                    seg.metricName = firstMetricName(vendor: newVendor, account: seg.account) ?? ""
                    seg.display = defaultDisplay(
                        vendor: newVendor,
                        account: seg.account,
                        metricName: seg.metricName
                    )
                    binding.wrappedValue = seg
                }
            )) {
                ForEach(vendors, id: \.rawValue) { vendor in
                    Text(VendorBranding.displayName(for: vendor)).tag(vendor)
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
        }
    }

    // MARK: Account

    private func accountPicker(_ binding: Binding<MenuBarSegmentConfig>) -> some View {
        let accounts = availableAccounts(for: binding.wrappedValue.vendor)
        return HStack {
            Text("Account")
                .frame(width: 80, alignment: .leading)
            Picker("", selection: Binding(
                get: { binding.wrappedValue.account },
                set: { newAccount in
                    var seg = binding.wrappedValue
                    seg.account = newAccount
                    if firstMetricName(vendor: seg.vendor, account: newAccount) == nil {
                        // No metrics on new account — keep metric name so the warning shows
                    } else if !metricExists(on: seg.vendor, account: newAccount, name: seg.metricName) {
                        seg.metricName = firstMetricName(vendor: seg.vendor, account: newAccount) ?? ""
                        seg.display = defaultDisplay(
                            vendor: seg.vendor,
                            account: newAccount,
                            metricName: seg.metricName
                        )
                    }
                    binding.wrappedValue = seg
                }
            )) {
                Text("Currently active account").tag(AccountSelection.currentlyActive)
                Divider()
                ForEach(accounts, id: \.rawValue) { email in
                    Text(email.rawValue).tag(AccountSelection.specific(email))
                }
            }
            .labelsHidden()
        }
    }

    // MARK: Metric

    private func metricPicker(_ binding: Binding<MenuBarSegmentConfig>) -> some View {
        let metrics = availableMetrics(
            vendor: binding.wrappedValue.vendor,
            account: binding.wrappedValue.account
        )
        return HStack {
            Text("Metric")
                .frame(width: 80, alignment: .leading)
            if metrics.isEmpty {
                Text("No metrics available")
                    .foregroundStyle(.secondary)
                    .font(.caption)
            } else {
                Picker("", selection: Binding(
                    get: { binding.wrappedValue.metricName },
                    set: { newName in
                        var seg = binding.wrappedValue
                        seg.metricName = newName
                        seg.display = defaultDisplay(
                            vendor: seg.vendor,
                            account: seg.account,
                            metricName: newName
                        )
                        binding.wrappedValue = seg
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

    // MARK: Time-window editor

    private func timeWindowEditor(_ binding: Binding<MenuBarSegmentConfig>) -> some View {
        let displayBinding = Binding<TimeWindowDisplay>(
            get: {
                if case .timeWindow(let d) = binding.wrappedValue.display {
                    return d
                }
                return TimeWindowDisplay()
            },
            set: { newDisplay in
                var seg = binding.wrappedValue
                seg.display = .timeWindow(newDisplay)
                binding.wrappedValue = seg
            }
        )

        return VStack(alignment: .leading, spacing: 8) {
            Text("Display")
                .font(.caption)
                .foregroundStyle(.secondary)
                .textCase(.uppercase)

            Toggle("Show vendor icon", isOn: displayBinding.showVendorIcon)
            Toggle("Colored status dot", isOn: displayBinding.showDot)
            HStack {
                Toggle("Metric short label", isOn: displayBinding.showLetter)
                    .fixedSize()
                TextField("", text: displayBinding.letter)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 48)
            }
            Toggle("Usage percentage", isOn: displayBinding.showPercent)
            Toggle("Time until reset", isOn: displayBinding.showReset)
        }
    }

    // MARK: Pay-as-you-go info

    private func payAsYouGoInfo(_ binding: Binding<MenuBarSegmentConfig>) -> some View {
        let preview = previewPayAsYouGo(for: binding.wrappedValue) ?? "—"
        return HStack(spacing: 6) {
            Image(systemName: "info.circle")
                .foregroundStyle(.secondary)
            Text("This metric displays \"\(preview)\" — no additional options.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: Data helpers

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

    private func availableMetrics(
        vendor: Vendor,
        account: AccountSelection
    ) -> [MetricOption] {
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

    private func defaultDisplay(
        vendor: Vendor,
        account: AccountSelection,
        metricName: String
    ) -> SegmentDisplay {
        guard let entry = resolveEntry(vendor: vendor, account: account),
              let metric = entry.metrics.first(where: { SegmentEditingHelpers.metricName($0) == metricName }) else {
            return .timeWindow(TimeWindowDisplay(letter: MenuBarMetricLetter.defaultLetter(for: metricName)))
        }
        switch metric {
        case .payAsYouGo:
            return .payAsYouGo
        case .timeWindow, .unknown:
            return .timeWindow(TimeWindowDisplay(letter: MenuBarMetricLetter.defaultLetter(for: metricName)))
        }
    }

    private func previewPayAsYouGo(for segment: MenuBarSegmentConfig) -> String? {
        guard let entry = resolveEntry(vendor: segment.vendor, account: segment.account),
              let metric = entry.metrics.first(where: { SegmentEditingHelpers.metricName($0) == segment.metricName }),
              case let .payAsYouGo(_, amount, currency) = metric else {
            return nil
        }
        return String(format: "%.2f %@", amount, currency)
    }
}
