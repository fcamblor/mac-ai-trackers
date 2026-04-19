import SwiftUI
import AIUsagesTrackersLib

/// Scrollable popover anchored to the menu bar item; uses LazyVStack + maxHeight
/// so the popover does not stretch unboundedly when many accounts are present.
struct UsageDetailsView: View {
    let store: UsageStore
    let refreshState: RefreshState
    let onRefresh: () async -> Void
    let onOpenSettings: () -> Void
    let onQuit: () -> Void


    private static let maxPopoverHeight: CGFloat = 480
    private static let popoverWidth: CGFloat = 320

    var body: some View {
        let sorted = store.entries.sortedForDisplay()
        let multiVendors = store.entries.vendorsWithMultipleAccounts()

        VStack(spacing: 0) {
            if sorted.isEmpty {
                emptyState
            } else {
                ScrollView {
                    LazyVStack(spacing: 8) {
                        ForEach(sorted) { entry in
                            AccountCardView(
                                entry: entry,
                                showActiveBadge: multiVendors.contains(entry.vendor),
                                isRefreshing: refreshState.isRefreshing(
                                    vendor: entry.vendor,
                                    account: entry.account
                                )
                            )
                        }
                    }
                    .padding(12)
                }
                .frame(maxHeight: Self.maxPopoverHeight)
                .background(Color(NSColor.windowBackgroundColor).opacity(0.4))
            }

            Divider()

            footer
        }
        .frame(width: Self.popoverWidth)
    }

    // MARK: - Subviews

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
        let refreshing = !refreshState.inFlight.isEmpty
        return HStack(spacing: 8) {
            Text("AI Usages Tracker")
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
            Spacer()

            Button {
                onOpenSettings()
            } label: {
                Image(systemName: "gearshape")
                    .frame(width: 16, height: 16)
            }
            .buttonStyle(.borderless)
            .controlSize(.small)
            .help("Settings")
            .keyboardShortcut(",", modifiers: .command)
            .focusable(false)

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
            }
            .buttonStyle(.borderless)
            .controlSize(.small)
            .disabled(refreshing)
            .help("Refresh usage data")
            .keyboardShortcut("r")
            .focusable(false)

            Button("Quit") {
                onQuit()
            }
            .keyboardShortcut("q")
            .controlSize(.small)
            .focusable(false)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }
}
