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
                MetricSelectionEditor(
                    store: store,
                    vendor: segmentBinding.vendor,
                    account: segmentBinding.account,
                    metricName: segmentBinding.metricName,
                    onMetricChanged: { metric in
                        var segment = segmentBinding.wrappedValue
                        segment.display = defaultDisplay(metric: metric, metricName: segment.metricName)
                        segmentBinding.wrappedValue = segment
                    }
                )

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
            Picker("Percentage value", selection: displayBinding.percentDisplayMode) {
                Text("Consumed").tag(UsagePercentDisplayMode.consumed)
                Text("Remaining").tag(UsagePercentDisplayMode.remaining)
            }
            .disabled(!displayBinding.wrappedValue.showPercent)
            .padding(.leading, 20)
            Toggle("Time until reset", isOn: displayBinding.showReset)
            Toggle("Hide minutes when over 1 day", isOn: displayBinding.hideResetMinutesWhenOverOneDay)
                .disabled(!displayBinding.wrappedValue.showReset)
                .padding(.leading, 20)
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

    private func resolveEntry(vendor: Vendor, account: AccountSelection) -> VendorUsageEntry? {
        let vendorEntries = store.entries.filter { $0.vendor == vendor }
        switch account {
        case .currentlyActive:
            return vendorEntries.first(where: { $0.isActive })
        case .specific(let email):
            return vendorEntries.first(where: { $0.account == email })
        }
    }

    private func defaultDisplay(metric: UsageMetric?, metricName: String) -> SegmentDisplay {
        guard let metric else {
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
