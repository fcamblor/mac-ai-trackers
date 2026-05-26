import SwiftUI
import AppKit
import AIUsagesTrackersLib

/// Edits the display options of a single chip sub-segment. Chip-level chrome
/// (vendor icon, outage warning) lives in `ChipCardView` so this editor stays
/// focused on what a single segment renders.
struct SegmentEditor: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    let preferences: any AppPreferences
    @Bindable var store: UsageStore
    let chipID: UUID
    let segmentID: UUID
    let isDark: Bool

    private var chipBinding: Binding<MenuBarChipConfig>? {
        SettingsConfigurationBindings.menuBarChip(preferences: preferences, chipID: chipID)
    }

    private var segmentBinding: Binding<MenuBarChipSegmentConfig>? {
        SettingsConfigurationBindings.menuBarChipSegment(
            preferences: preferences,
            chipID: chipID,
            segmentID: segmentID
        )
    }

    var body: some View {
        if let chipBinding, let segmentBinding {
            let vendor = chipBinding.wrappedValue.vendor
            VStack(alignment: .leading, spacing: 14) {
                MetricSelectionEditor(
                    store: store,
                    vendor: .constant(vendor),
                    account: segmentBinding.account,
                    metricName: segmentBinding.metricName,
                    layout: .grid,
                    showVendorPicker: false,
                    onMetricChanged: { metric in
                        var seg = segmentBinding.wrappedValue
                        seg.display = defaultDisplay(metric: metric, metricName: seg.metricName)
                        segmentBinding.wrappedValue = seg
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
    private func timeWindowSection(_ binding: Binding<MenuBarChipSegmentConfig>) -> some View {
        let displayBinding = timeWindowDisplayBinding(binding)

        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                sectionTitle("Segment pieces")
                Text("— click a piece to toggle it")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }

            chipStrip(display: displayBinding)
            subOptionsPanel(display: displayBinding)
        }
    }

    // MARK: Chip strip

    @ViewBuilder
    private func chipStrip(display: Binding<TimeWindowDisplay>) -> some View {
        HStack(alignment: .top, spacing: 6) {
            chip(
                caption: "Label",
                isOn: display.wrappedValue.showLetter,
                canToggleOff: canToggleOff(display: display.wrappedValue, candidate: \.showLetter),
                toggle: { toggleVisibility(display: display, keyPath: \.showLetter) }
            ) {
                Text(display.wrappedValue.letter.isEmpty ? "·" : display.wrappedValue.letter)
                    .font(.system(size: 13, weight: .semibold, design: .monospaced))
            }

            chipConnector

            chip(
                caption: "Percent",
                isOn: display.wrappedValue.showPercent,
                canToggleOff: canToggleOff(display: display.wrappedValue, candidate: \.showPercent),
                toggle: { toggleVisibility(display: display, keyPath: \.showPercent) }
            ) {
                Text(percentSamplePreview(display: display.wrappedValue))
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
            }

            chipConnector

            chip(
                caption: "Reset",
                isOn: display.wrappedValue.showReset,
                canToggleOff: canToggleOff(display: display.wrappedValue, candidate: \.showReset),
                toggle: { toggleVisibility(display: display, keyPath: \.showReset) }
            ) {
                Text(resetSamplePreview(display: display.wrappedValue))
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
            }

            Spacer(minLength: 0)
        }
    }

    /// Enforces the per-segment invariant: at least one of the three visible
    /// toggles must stay on.
    private func canToggleOff(
        display: TimeWindowDisplay,
        candidate keyPath: WritableKeyPath<TimeWindowDisplay, Bool>
    ) -> Bool {
        var rest = display
        rest[keyPath: keyPath] = false
        return rest.hasAnyVisibleElement
    }

    /// Toggling on is always allowed. Toggling off goes through the invariant
    /// check; when the segment would otherwise become empty, the user gets a
    /// disabled chip instead of a silent no-op.
    private func toggleVisibility(
        display: Binding<TimeWindowDisplay>,
        keyPath: WritableKeyPath<TimeWindowDisplay, Bool>
    ) {
        let current = display.wrappedValue[keyPath: keyPath]
        if current && !canToggleOff(display: display.wrappedValue, candidate: keyPath) {
            return
        }
        display.wrappedValue[keyPath: keyPath].toggle()
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
        canToggleOff: Bool,
        toggle: @escaping () -> Void,
        @ViewBuilder symbol: () -> Symbol
    ) -> some View {
        let lockedOn = isOn && !canToggleOff
        return Button(action: {
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
        .help(lockedOn
              ? "A segment needs at least one visible piece — toggle another one on first."
              : (isOn ? "\(caption) shown — click to hide" : "\(caption) hidden — click to show"))
        .opacity(lockedOn ? 0.7 : 1.0)
    }

    private func percentSamplePreview(display: TimeWindowDisplay) -> String {
        switch display.percentDisplayMode {
        case .consumed:  return "42%"
        case .remaining: return "58%"
        }
    }

    private func resetSamplePreview(display: TimeWindowDisplay) -> String {
        display.hideResetMinutesWhenOverOneDay ? "2d 4h" : "2d 4h 15m"
    }

    // MARK: Sub-options panel

    @ViewBuilder
    private func subOptionsPanel(display: Binding<TimeWindowDisplay>) -> some View {
        let hasLetter = display.wrappedValue.showLetter
        let hasPercent = display.wrappedValue.showPercent
        let hasReset = display.wrappedValue.showReset
        let anyOption = hasLetter || hasPercent || hasReset

        if anyOption {
            VStack(alignment: .leading, spacing: 8) {
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

    private func payAsYouGoSection(_ binding: Binding<MenuBarChipSegmentConfig>) -> some View {
        let preview = previewPayAsYouGo(for: binding.wrappedValue) ?? "—"
        return HStack(spacing: 6) {
            Image(systemName: "info.circle")
                .foregroundStyle(.secondary)
            Text("Displays \"\(preview)\" — no display pieces to toggle.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: Bindings

    private func timeWindowDisplayBinding(
        _ binding: Binding<MenuBarChipSegmentConfig>
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

    private func previewPayAsYouGo(for segment: MenuBarChipSegmentConfig) -> String? {
        guard let chipBinding else { return nil }
        guard let entry = resolveEntry(vendor: chipBinding.wrappedValue.vendor, account: segment.account),
              let metric = entry.metrics.first(where: { SegmentEditingHelpers.metricName($0) == segment.metricName }),
              case let .payAsYouGo(_, amount, currency) = metric else {
            return nil
        }
        return String(format: "%.2f %@", amount, currency)
    }
}
