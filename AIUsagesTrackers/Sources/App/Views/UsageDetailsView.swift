import SwiftUI
import AIUsagesTrackersLib

/// Scrollable popover anchored to the menu bar item; uses LazyVStack + maxHeight
/// so the popover does not stretch unboundedly when many accounts are present.
struct UsageDetailsView: View {
    let store: UsageStore
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
                                showActiveBadge: multiVendors.contains(entry.vendor)
                            )
                        }
                    }
                    .padding(12)
                }
                .frame(maxHeight: Self.maxPopoverHeight)
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
        HStack {
            Text("AI Usages Tracker")
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
            Spacer()
            Button("Quit") {
                onQuit()
            }
            .keyboardShortcut("q")
            .controlSize(.small)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }
}
