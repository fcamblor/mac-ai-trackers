import SwiftUI
import AppKit
import AIUsagesTrackersLib

struct SegmentEditor: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    let preferences: any AppPreferences
    @Bindable var store: UsageStore
    let segmentID: UUID
    let isDark: Bool

    private var segmentBinding: Binding<MenuBarSegmentConfig>? {
        SettingsConfigurationBindings.menuBarSegment(preferences: preferences, segmentID: segmentID)
    }

    var body: some View {
        if let segmentBinding {
            VStack(alignment: .leading, spacing: 14) {
                MetricSelectionEditor(
                    store: store,
                    vendor: segmentBinding.vendor,
                    account: segmentBinding.account,
                    metricName: segmentBinding.metricName,
                    layout: .grid,
                    onMetricChanged: { metric in
                        var segment = segmentBinding.wrappedValue
                        segment.display = defaultDisplay(metric: metric, metricName: segment.metricName)
                        segmentBinding.wrappedValue = segment
                    }
                )

                Divider()

                switch segmentBinding.wrappedValue.display {
                case .timeWindow:
                    timeWindowSection(segmentBinding)
                case .payAsYouGo:
                    payAsYouGoSection(segmentBinding)
                }
            }
        }
    }

    // MARK: Section header

    private func sectionTitle(_ text: String) -> some View {
        Text(text)
            .font(.caption2)
            .fontWeight(.semibold)
            .tracking(0.8)
            .textCase(.uppercase)
            .foregroundStyle(.secondary)
    }

    // MARK: Time-window — chip strip + sub-options

    @ViewBuilder
    private func timeWindowSection(_ binding: Binding<MenuBarSegmentConfig>) -> some View {
        let displayBinding = timeWindowDisplayBinding(binding)
        let segment = binding.wrappedValue

        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                sectionTitle("Menu bar pieces")
                Text("— click a piece to toggle it")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }

            chipStrip(segment: segment, binding: binding, display: displayBinding)

            subOptionsPanel(segment: segment, binding: binding, display: displayBinding)
        }
    }

    // MARK: Chip strip

    @ViewBuilder
    private func chipStrip(
        segment: MenuBarSegmentConfig,
        binding: Binding<MenuBarSegmentConfig>,
        display: Binding<TimeWindowDisplay>
    ) -> some View {
        HStack(alignment: .top, spacing: 6) {
            chip(
                caption: "Icon",
                isOn: display.wrappedValue.showVendorIcon,
                toggle: { display.wrappedValue.showVendorIcon.toggle() }
            ) {
                VendorIconView(vendor: segment.vendor, size: 14)
            }

            chipConnector

            chip(
                caption: "Outage",
                isOn: segment.showOutageWarning,
                toggle: {
                    var seg = binding.wrappedValue
                    seg.showOutageWarning.toggle()
                    binding.wrappedValue = seg
                }
            ) {
                Text(segment.outageWarningText.isEmpty ? "⚠️" : segment.outageWarningText)
                    .font(.system(size: 13))
            }

            chipConnector

            chip(
                caption: "Dot",
                isOn: display.wrappedValue.showDot,
                toggle: { display.wrappedValue.showDot.toggle() }
            ) {
                Circle()
                    .fill(Color.green)
                    .overlay(Circle().stroke(Color.primary.opacity(0.35), lineWidth: 0.6))
                    .frame(width: 9, height: 9)
            }

            chipConnector

            chip(
                caption: "Label",
                isOn: display.wrappedValue.showLetter,
                toggle: { display.wrappedValue.showLetter.toggle() }
            ) {
                Text(display.wrappedValue.letter.isEmpty ? "·" : display.wrappedValue.letter)
                    .font(.system(size: 13, weight: .semibold, design: .monospaced))
            }

            chipConnector

            chip(
                caption: "Percent",
                isOn: display.wrappedValue.showPercent,
                toggle: { display.wrappedValue.showPercent.toggle() }
            ) {
                Text(percentSamplePreview(display: display.wrappedValue))
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
            }

            chipConnector

            chip(
                caption: "Reset",
                isOn: display.wrappedValue.showReset,
                toggle: { display.wrappedValue.showReset.toggle() }
            ) {
                Text(resetSamplePreview(display: display.wrappedValue))
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
            }

            Spacer(minLength: 0)
        }
    }

    private var chipConnector: some View {
        Image(systemName: "chevron.right")
            .font(.system(size: 8, weight: .semibold))
            .foregroundStyle(.tertiary)
            .frame(height: 32)
    }

    private func chip<Symbol: View>(
        caption: String,
        isOn: Bool,
        toggle: @escaping () -> Void,
        @ViewBuilder symbol: () -> Symbol
    ) -> some View {
        Button(action: {
            withAnimation(.easeOut(duration: 0.14)) { toggle() }
        }) {
            VStack(spacing: 4) {
                ZStack {
                    RoundedRectangle(cornerRadius: 6)
                        .fill(isOn ? Color.accentColor.opacity(0.16) : Color.clear)
                    RoundedRectangle(cornerRadius: 6)
                        .strokeBorder(
                            isOn ? Color.accentColor.opacity(0.85) : Color.secondary.opacity(0.45),
                            style: StrokeStyle(
                                lineWidth: 1,
                                dash: isOn ? [] : [3, 2]
                            )
                        )
                    symbol()
                        .opacity(isOn ? 1.0 : 0.4)
                }
                .frame(width: 48, height: 32)
                .contentShape(RoundedRectangle(cornerRadius: 6))

                Text(caption)
                    .font(.system(size: 9, weight: isOn ? .semibold : .regular))
                    .tracking(0.4)
                    .textCase(.uppercase)
                    .foregroundStyle(isOn ? Color.primary : Color.secondary)
            }
        }
        .buttonStyle(.plain)
        .help(isOn ? "\(caption) shown — click to hide" : "\(caption) hidden — click to show")
    }

    private func percentSamplePreview(display: TimeWindowDisplay) -> String {
        switch display.percentDisplayMode {
        case .consumed:  return "42%"
        case .remaining: return "58%"
        }
    }

    private func resetSamplePreview(display: TimeWindowDisplay) -> String {
        // Sample assumes a > 1 day countdown so the toggle's effect is visible.
        // See formatRemainingTime in UsageComputations.swift.
        display.hideResetMinutesWhenOverOneDay ? "2d 4h" : "2d 4h 15m"
    }

    // MARK: Sub-options panel

    @ViewBuilder
    private func subOptionsPanel(
        segment: MenuBarSegmentConfig,
        binding: Binding<MenuBarSegmentConfig>,
        display: Binding<TimeWindowDisplay>
    ) -> some View {
        let hasOutage = segment.showOutageWarning
        let hasLetter = display.wrappedValue.showLetter
        let hasPercent = display.wrappedValue.showPercent
        let hasReset = display.wrappedValue.showReset
        let anyOption = hasOutage || hasLetter || hasPercent || hasReset

        if anyOption {
            VStack(alignment: .leading, spacing: 8) {
                if hasOutage {
                    subOptionRow(label: "Outage text") {
                        TextField("", text: outageTextBinding(binding))
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 64)
                    }
                }
                if hasLetter {
                    subOptionRow(label: "Label letter") {
                        TextField("", text: display.letter)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 64)
                    }
                }
                if hasPercent {
                    subOptionRow(label: "Percent shows") {
                        Picker("", selection: display.percentDisplayMode) {
                            Text("Consumed").tag(UsagePercentDisplayMode.consumed)
                            Text("Remaining").tag(UsagePercentDisplayMode.remaining)
                        }
                        .labelsHidden()
                        .pickerStyle(.segmented)
                        .frame(width: 200)
                    }
                }
                if hasReset {
                    subOptionRow(label: "Reset format") {
                        Toggle("Hide minutes when over 1 day", isOn: display.hideResetMinutesWhenOverOneDay)
                            .toggleStyle(.checkbox)
                            .fixedSize()
                    }
                }
            }
            .padding(10)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color.secondary.opacity(0.07))
            )
            .transition(subOptionsTransition)
        }
    }

    private var subOptionsTransition: AnyTransition {
        guard !reduceMotion else { return .identity }
        return .asymmetric(
            insertion: .opacity.combined(with: .scale(scale: 0.985, anchor: .top)),
            removal: .opacity
        )
    }

    private func subOptionRow<Control: View>(
        label: String,
        @ViewBuilder _ control: () -> Control
    ) -> some View {
        HStack(spacing: 10) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 100, alignment: .leading)
            control()
            Spacer(minLength: 0)
        }
    }

    // MARK: Pay-as-you-go

    private func payAsYouGoSection(_ binding: Binding<MenuBarSegmentConfig>) -> some View {
        let preview = previewPayAsYouGo(for: binding.wrappedValue) ?? "—"
        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: "info.circle")
                    .foregroundStyle(.secondary)
                Text("Displays \"\(preview)\" — no display pieces to toggle.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            HStack(spacing: 8) {
                chip(
                    caption: "Outage",
                    isOn: binding.wrappedValue.showOutageWarning,
                    toggle: {
                        var seg = binding.wrappedValue
                        seg.showOutageWarning.toggle()
                        binding.wrappedValue = seg
                    }
                ) {
                    Text(binding.wrappedValue.outageWarningText.isEmpty ? "⚠️" : binding.wrappedValue.outageWarningText)
                        .font(.system(size: 13))
                }
                if binding.wrappedValue.showOutageWarning {
                    TextField("", text: outageTextBinding(binding))
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 64)
                }
            }
        }
    }

    // MARK: Bindings

    private func timeWindowDisplayBinding(
        _ binding: Binding<MenuBarSegmentConfig>
    ) -> Binding<TimeWindowDisplay> {
        Binding<TimeWindowDisplay>(
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
    }

    private func outageTextBinding(_ binding: Binding<MenuBarSegmentConfig>) -> Binding<String> {
        Binding<String>(
            get: { binding.wrappedValue.outageWarningText },
            set: { newValue in
                var seg = binding.wrappedValue
                seg.outageWarningText = newValue
                binding.wrappedValue = seg
            }
        )
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
