import SwiftUI
import AppKit
import AIUsagesTrackersLib

struct AssistantsSettingsView: View {
    let preferences: any AppPreferences

    var body: some View {
        Form {
            Section("Accounts") {
                AccountsOrderingSection()
            }
            Section("Ignored accounts") {
                IgnoredAccountsSection()
            }
            Section("Claude Code credentials") {
                KeychainDiagnosticView()
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Ignored accounts section (relocated from General)

private struct IgnoredAccountsSection: View {
    private var prefs: UserDefaultsAppPreferences { AppDelegate.sharedPreferences }

    var body: some View {
        Text("Right-click an account in the popover or use the eye icon in the Accounts list above to ignore it.")
            .font(.caption)
            .foregroundStyle(.secondary)
        if prefs.ignoredAccounts.isEmpty {
            Text("No ignored accounts.")
                .foregroundStyle(.secondary)
        } else {
            ForEach(prefs.ignoredAccounts, id: \.self) { ignored in
                HStack(spacing: 8) {
                    VendorIconView(vendor: ignored.vendor, size: 13)
                    Text(ignored.account.rawValue)
                        .font(.system(size: 12))
                    Spacer()
                    Button(role: .destructive) {
                        prefs.ignoredAccounts.removeAll { $0 == ignored }
                    } label: {
                        Image(systemName: "trash")
                    }
                    .buttonStyle(.borderless)
                }
            }
            Button("Remove all", role: .destructive) {
                prefs.ignoredAccounts = []
            }
        }
    }
}

// MARK: - Accounts ordering section

/// Lists every currently-detected, non-ignored account in the user-chosen
/// order and lets the user drag-reorder them or ignore them. Mirrors the
/// drag pattern used in `ChartSettingsView` / `SegmentCardView` (gesture on
/// the handle, named coordinate space, drop indicator capsule). The order is
/// persisted as `accountsOrder` and applied in the popover via
/// `sortedForDisplay(order:)`.
private struct AccountsOrderingSection: View {
    var body: some View {
        if let store = AppDelegate.sharedStore {
            AccountsOrderingContent(store: store)
        } else {
            Text("Loading accounts…")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

private struct AccountRowFramePreferenceKey: PreferenceKey {
    static let defaultValue: [String: CGRect] = [:]
    static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) {
        value.merge(nextValue()) { _, new in new }
    }
}

/// Tracks the live drag cursor Y so the floating preview can follow it
/// without forcing a re-layout of the underlying list on every frame.
@MainActor
private final class AccountListDragCursorTracker: ObservableObject {
    @Published var y: CGFloat = 0
}

private struct AccountsOrderingContent: View {
    @Bindable var store: UsageStore

    private static let coordinateSpaceName = "assistants.accountsOrdering"

    private var prefs: UserDefaultsAppPreferences { AppDelegate.sharedPreferences }

    @State private var rowFrames: [String: CGRect] = [:]
    @State private var draggingID: String?
    @State private var dropIndex: Int?
    @StateObject private var cursorTracker = AccountListDragCursorTracker()

    private var visibleEntries: [VendorUsageEntry] {
        store.entries
            .excluding(ignoredAccounts: prefs.ignoredAccounts)
            .sortedForDisplay(order: prefs.accountsOrder)
    }

    var body: some View {
        let entries = visibleEntries
        if entries.isEmpty {
            Text("No accounts detected yet.")
                .font(.caption)
                .foregroundStyle(.secondary)
        } else {
            VStack(alignment: .leading, spacing: 6) {
                Text("Drag the handle to reorder. The popover displays accounts in this order.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                ZStack(alignment: .topLeading) {
                    LazyVStack(spacing: 2) {
                        ForEach(entries, id: \.id) { entry in
                            row(for: entry)
                        }
                    }
                    .animation(.spring(response: 0.34, dampingFraction: 0.85), value: draggingID)
                    .animation(.spring(response: 0.34, dampingFraction: 0.85), value: dropIndex)
                    dropIndicator(entries: entries)
                    floatingPreview(entries: entries)
                }
                .coordinateSpace(name: Self.coordinateSpaceName)
                .onPreferenceChange(AccountRowFramePreferenceKey.self) { rowFrames = $0 }
            }
        }
    }

    private func row(for entry: VendorUsageEntry) -> some View {
        let isDragging = draggingID == entry.id
        return AccountOrderingRow(
            entry: entry,
            isBeingDragged: isDragging,
            dragCoordinateSpace: Self.coordinateSpaceName,
            onIgnore: { ignore(entry: entry) },
            onDragChanged: { value in handleDragChanged(value: value, entryID: entry.id) },
            onDragEnded: { value in handleDragEnded(value: value, entryID: entry.id) }
        )
        .background(
            GeometryReader { geo in
                Color.clear.preference(
                    key: AccountRowFramePreferenceKey.self,
                    value: [entry.id: geo.frame(in: .named(Self.coordinateSpaceName))]
                )
            }
        )
        .opacity(isDragging ? 0.0 : 1.0)
        .frame(maxHeight: isDragging ? 0 : nil)
        .clipped()
    }

    @ViewBuilder
    private func dropIndicator(entries: [VendorUsageEntry]) -> some View {
        if let dropIndex, let y = dropIndicatorY(entries: entries, atIndex: dropIndex) {
            Capsule()
                .fill(Color.accentColor)
                .frame(height: 2)
                .padding(.horizontal, 4)
                .offset(y: y - 1)
                .allowsHitTesting(false)
        }
    }

    private func dropIndicatorY(entries: [VendorUsageEntry], atIndex index: Int) -> CGFloat? {
        let visible = entries.filter { $0.id != draggingID }
        guard !visible.isEmpty else { return 0 }
        let clamped = max(0, min(index, visible.count))
        if clamped == 0 {
            return rowFrames[visible[0].id]?.minY
        }
        if clamped >= visible.count {
            return rowFrames[visible.last!.id]?.maxY
        }
        let prev = rowFrames[visible[clamped - 1].id]?.maxY ?? 0
        let next = rowFrames[visible[clamped].id]?.minY ?? prev
        return (prev + next) / 2
    }

    @ViewBuilder
    private func floatingPreview(entries: [VendorUsageEntry]) -> some View {
        if let id = draggingID,
           let entry = entries.first(where: { $0.id == id }),
           let frame = rowFrames[id] {
            AccountListFloatingDragPreview(
                tracker: cursorTracker,
                entry: entry,
                frame: frame
            )
        }
    }

    private func handleDragChanged(value: DragGesture.Value, entryID: String) {
        if draggingID == nil {
            draggingID = entryID
        }
        cursorTracker.y = value.location.y
        let entries = visibleEntries
        let newDropIndex = computeDropIndex(at: value.location.y, entries: entries)
        if newDropIndex != dropIndex {
            dropIndex = newDropIndex
        }
    }

    private func handleDragEnded(value: DragGesture.Value, entryID: String) {
        let entries = visibleEntries
        let finalIndex = computeDropIndex(at: value.location.y, entries: entries)
        performDrop(draggedID: entryID, toVisibleIndex: finalIndex, entries: entries)
        withAnimation(.spring(response: 0.34, dampingFraction: 0.82)) {
            draggingID = nil
            dropIndex = nil
        }
    }

    private func computeDropIndex(at y: CGFloat, entries: [VendorUsageEntry]) -> Int {
        let visible = entries.filter { $0.id != draggingID }
        for (idx, entry) in visible.enumerated() {
            guard let frame = rowFrames[entry.id] else { continue }
            if y < frame.midY { return idx }
        }
        return visible.count
    }

    private func performDrop(draggedID: String, toVisibleIndex visibleIndex: Int, entries: [VendorUsageEntry]) {
        var ids = entries.map(\.id)
        guard let sourceIdx = ids.firstIndex(of: draggedID) else { return }
        let destOffset: Int
        if visibleIndex >= sourceIdx {
            destOffset = visibleIndex + 1
        } else {
            destOffset = visibleIndex
        }
        if destOffset == sourceIdx || destOffset == sourceIdx + 1 { return }
        ids.move(fromOffsets: IndexSet(integer: sourceIdx), toOffset: destOffset)
        prefs.accountsOrder = ids
    }

    private func ignore(entry: VendorUsageEntry) {
        let ignored = IgnoredAccount(vendor: entry.vendor, account: entry.account)
        if !prefs.ignoredAccounts.contains(ignored) {
            prefs.ignoredAccounts.append(ignored)
        }
    }
}

private struct AccountOrderingRow: View {
    let entry: VendorUsageEntry
    let isBeingDragged: Bool
    let dragCoordinateSpace: String
    let onIgnore: () -> Void
    let onDragChanged: (DragGesture.Value) -> Void
    let onDragEnded: (DragGesture.Value) -> Void

    @State private var isHovering = false

    var body: some View {
        HStack(spacing: 8) {
            dragHandle
            VendorIconView(vendor: entry.vendor, size: 13)
            Text(entry.account.rawValue)
                .font(.system(size: 12))
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer()
            Button {
                onIgnore()
            } label: {
                Image(systemName: "eye.slash")
            }
            .buttonStyle(.borderless)
            .help("Ignore this account")
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 6)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(isHovering ? Color.secondary.opacity(0.07) : Color.clear)
        )
        .onHover { isHovering = $0 }
    }

    private var dragHandle: some View {
        Image(systemName: "line.3.horizontal")
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(isHovering ? Color.secondary : Color.secondary.opacity(0.55))
            .frame(width: 18, height: 22)
            .contentShape(Rectangle())
            .help("Drag to reorder")
            .onHover { hovering in
                if hovering {
                    NSCursor.openHand.push()
                } else {
                    NSCursor.pop()
                }
            }
            .gesture(
                DragGesture(minimumDistance: 4, coordinateSpace: .named(dragCoordinateSpace))
                    .onChanged(onDragChanged)
                    .onEnded(onDragEnded)
            )
    }
}

/// Static visual of an account row used as the floating drag preview.
/// Mirrors the in-list row so the user keeps a consistent mental anchor
/// while dragging, but strips interactive bits (hover, cursor, button).
private struct AccountDragPreviewCard: View {
    let entry: VendorUsageEntry

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "line.3.horizontal")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 18, height: 22)
            VendorIconView(vendor: entry.vendor, size: 13)
            Text(entry.account.rawValue)
                .font(.system(size: 12))
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 0)
            Image(systemName: "eye.slash")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 6)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(.background)
                .shadow(color: .black.opacity(0.28), radius: 14, x: 0, y: 6)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.accentColor.opacity(0.5), lineWidth: 1)
        )
        .rotationEffect(.degrees(-1.2))
        .scaleEffect(1.02)
    }
}

private struct AccountListFloatingDragPreview: View {
    @ObservedObject var tracker: AccountListDragCursorTracker
    let entry: VendorUsageEntry
    let frame: CGRect

    var body: some View {
        AccountDragPreviewCard(entry: entry)
            .frame(width: max(frame.width, 240))
            .offset(x: frame.minX, y: tracker.y - frame.height / 2)
            .allowsHitTesting(false)
    }
}

/// On-demand diagnostic that inspects the macOS Keychain entries written by
/// the `claude` CLI under "Claude Code-credentials" and lets the user pick
/// which entry the runtime should read from. The app never deletes or
/// modifies entries written by the vendor — picking an entry only updates a
/// local preference so the runtime can target it by `kSecAttrAccount`.
///
/// The runtime's own credential locator auto-pins the first readable
/// `claudeAiOauth` entry it encounters during the background poll, so most
/// users never need this tab. It exists as a remediation tool for the
/// multi-entry case where the auto-pin lands on the wrong entry (e.g. an MCP
/// OAuth state item that the `claude` CLI keeps under the same service).
private struct KeychainDiagnosticView: View {
    @State private var phase: Phase = .idle

    private enum Phase: Equatable {
        case idle
        case running
        case success(KeychainDiagnosticReport)
        case failure(String)
    }

    private let scanner = KeychainDuplicatesScanner()
    private let credentialsService = ClaudeCredentialLocator.defaultKeychainService
    private var preferences: any AppPreferences { AppDelegate.sharedPreferences }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("The `claude` CLI stores its OAuth bearer in the macOS Keychain under the " +
                 "\"\(credentialsService)\" service. It sometimes leaves several generic-password " +
                 "items under that same service — typically one holding MCP plugin OAuth state and " +
                 "another holding the actual `claudeAiOauth` bearer. Without scoping the read, macOS " +
                 "returns whichever entry it ranks first, which may not be the one with a usable token.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Text("This diagnostic enumerates the entries the `claude` CLI wrote, identifies the one " +
                 "that actually carries `claudeAiOauth.accessToken`, and lets you pin the runtime to " +
                 "that specific entry. The app never deletes or modifies Keychain entries written by " +
                 "the vendor — the choice is stored as a local preference.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            selectionStatusRow

            Label {
                Text("The runtime already auto-pins the first readable `claudeAiOauth` entry, " +
                     "so you usually don't need to run this scan. Run it only if usage refreshes " +
                     "report a credential issue and you suspect the auto-pin landed on the wrong " +
                     "entry. The scan may trigger a one-off macOS Keychain authorisation prompt.")
                    .font(.caption)
                    .fixedSize(horizontal: false, vertical: true)
            } icon: {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
            }

            HStack(spacing: 8) {
                Button {
                    runScan()
                } label: {
                    if phase == .running {
                        HStack(spacing: 6) {
                            ProgressView().controlSize(.small)
                            Text("Scanning…")
                        }
                    } else {
                        Text("Run diagnostic")
                    }
                }
                .disabled(phase == .running)

                Spacer()
            }

            resultView
        }
        .padding(.vertical, 4)
    }

    private var selectionStatusRow: some View {
        let selected = preferences.claudeKeychainAccount

        return HStack(spacing: 8) {
            Image(systemName: selected == nil ? "circle.dashed" : "checkmark.circle.fill")
                .foregroundStyle(selected == nil ? Color.secondary : Color.green)
            VStack(alignment: .leading, spacing: 2) {
                Text("Selected entry")
                    .font(.caption.weight(.semibold))
                if let selected {
                    Text("`kSecAttrAccount = \(selected)`")
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                } else {
                    Text("None — the runtime reads the first match returned by `security`.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
        }
        .padding(8)
        .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))
    }

    @ViewBuilder
    private var resultView: some View {
        switch phase {
        case .idle, .running:
            EmptyView()
        case let .success(report):
            ReportView(report: report)
        case let .failure(message):
            Label {
                Text(message)
                    .font(.caption)
                    .fixedSize(horizontal: false, vertical: true)
            } icon: {
                Image(systemName: "xmark.octagon.fill")
                    .foregroundStyle(.red)
            }
        }
    }

    private func runScan() {
        phase = .running
        let scanner = scanner
        Task { @MainActor in
            do {
                let report = try await scanner.scan()
                phase = .success(report)
            } catch {
                phase = .failure(String(describing: error))
            }
        }
    }
}

private struct ReportView: View {
    let report: KeychainDiagnosticReport

    private var preferences: any AppPreferences { AppDelegate.sharedPreferences }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            headerBadge
            summaryLine
            if !report.entries.isEmpty {
                Divider()
                ForEach(Array(report.entries.enumerated()), id: \.offset) { _, entry in
                    EntryRow(entry: entry)
                }
            }
            if report.apiKeyDetected {
                Divider()
                Label {
                    Text("An `sk-ant-api…` API key is present under \"\(report.apiKeyServiceName)\". " +
                         "Usage metrics require Claude Code OAuth credentials — sign in with " +
                         "`claude` to generate an OAuth entry.")
                        .font(.caption)
                        .fixedSize(horizontal: false, vertical: true)
                } icon: {
                    Image(systemName: "info.circle.fill")
                        .foregroundStyle(.blue)
                }
            }
        }
    }

    @ViewBuilder
    private var headerBadge: some View {
        if report.totalEntries == 0 {
            badge(systemImage: "info.circle.fill", color: .secondary,
                  title: "No Keychain entry found for \"\(report.credentialsServiceName)\".",
                  subtitle: "If you only use Claude through a UI (Cowork, Claude Code Desktop, " +
                            "Claude Chat… anything other than the CLI), you still need to sign in " +
                            "at least once with the `claude` CLI so that your credentials get " +
                            "written to the macOS Keychain — that is the only place this app can " +
                            "read them from.")
        } else if report.hasDuplicates {
            badge(systemImage: "exclamationmark.octagon.fill", color: .orange,
                  title: "Several entries found under the same service.",
                  subtitle: "The runtime has been pinned to the first entry that carries " +
                            "`claudeAiOauth.accessToken`. Use \"Use this entry\" below if you " +
                            "want to target a different one — entries without a Claude OAuth block " +
                            "cannot be selected.")
        } else if report.hasUsableOAuthToken {
            badge(systemImage: "checkmark.seal.fill", color: .green,
                  title: "Claude Code credentials look healthy.",
                  subtitle: nil)
        } else if report.hasPinnableOAuthEntry, preferences.claudeKeychainAccount != nil {
            badge(systemImage: "clock.badge.exclamationmark.fill", color: .orange,
                  title: "Session expired.",
                  subtitle: "Re-authenticate with the `claude` CLI to refresh the credentials in place — " +
                            "the runtime is already targeting this entry and will pick up the " +
                            "new token on the next refresh.")
        } else {
            badge(systemImage: "exclamationmark.triangle.fill", color: .orange,
                  title: "No entry carries a `claudeAiOauth` block.",
                  subtitle: "Sign in with the `claude` CLI to populate the credentials, then run the " +
                            "diagnostic again.")
        }
    }

    private func badge(systemImage: String, color: Color, title: String, subtitle: String?) -> some View {
        Label {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.caption.weight(.semibold))
                if let subtitle {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        } icon: {
            Image(systemName: systemImage).foregroundStyle(color)
        }
    }

    private var summaryLine: some View {
        var parts: [String] = []
        parts.append("\(report.totalEntries) entr\(report.totalEntries == 1 ? "y" : "ies")")
        if !report.distinctAccounts.isEmpty {
            parts.append("accounts: \(report.distinctAccounts.joined(separator: ", "))")
        }
        if report.entriesWithoutAccount > 0 {
            parts.append("\(report.entriesWithoutAccount) without account")
        }
        return Text(parts.joined(separator: " · "))
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}

private struct EntryRow: View {
    let entry: KeychainDiagnosticReport.Entry
    @State private var hovering = false

    private var preferences: any AppPreferences { AppDelegate.sharedPreferences }

    private var isSelected: Bool {
        entry.account != nil && preferences.claudeKeychainAccount == entry.account
    }

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: icon).foregroundStyle(color)
            VStack(alignment: .leading, spacing: 2) {
                Text(accountLabel).font(.caption.weight(.medium))
                Text(statusLabel)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            actionButton
        }
        .padding(.vertical, 4)
    }

    private var isSelectable: Bool {
        guard let account = entry.account, !account.isEmpty else { return false }
        // Both states carry `claudeAiOauth` — expired entries are pinned now
        // and will resume working as soon as the `claude` CLI refreshes them.
        switch entry.status {
        case .validOAuthToken, .expiredOAuthToken: return true
        default: return false
        }
    }

    @ViewBuilder
    private var actionButton: some View {
        if isSelected {
            Label("Selected", systemImage: "checkmark.circle.fill")
                .font(.caption.weight(.semibold))
                .foregroundStyle(Color.green)
        } else if isSelectable, let account = entry.account {
            Button {
                preferences.claudeKeychainAccount = account
            } label: {
                Text("Use this entry")
                    .font(.caption)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        } else {
            Text(notSelectableReason)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    private var notSelectableReason: String {
        guard entry.account != nil, !(entry.account ?? "").isEmpty else {
            // No kSecAttrAccount → can't be addressed via `security -a`.
            return "Not addressable"
        }
        return "No usable token"
    }

    private var accountLabel: String {
        if let account = entry.account, !account.isEmpty {
            return "Account: \(account)"
        }
        return "Account: (none)"
    }

    private var icon: String {
        switch entry.status {
        case .validOAuthToken: "checkmark.circle.fill"
        case .expiredOAuthToken: "clock.badge.exclamationmark.fill"
        case .missingOAuthBlock, .unparseable, .empty: "questionmark.circle.fill"
        case .readDenied: "lock.slash.fill"
        }
    }

    private var color: Color {
        switch entry.status {
        case .validOAuthToken: .green
        case .expiredOAuthToken: .orange
        case .missingOAuthBlock, .unparseable, .empty: .secondary
        case .readDenied: .red
        }
    }

    private var statusLabel: String {
        switch entry.status {
        case let .validOAuthToken(expiresAt):
            if let expiresAt {
                return "Valid OAuth token — expires \(Self.dateFormatter.string(from: expiresAt))"
            }
            return "Valid OAuth token — no embedded expiry"
        case let .expiredOAuthToken(expiresAt):
            return "OAuth token expired on \(Self.dateFormatter.string(from: expiresAt))"
        case .missingOAuthBlock:
            return "JSON parsed but no `claudeAiOauth.accessToken` (likely an MCP OAuth state entry)"
        case let .unparseable(preview):
            return "Value is not JSON — preview: \(preview)"
        case .empty:
            return "Entry is empty"
        case let .readDenied(status):
            return "Read denied (OSStatus \(status))"
        }
    }

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }()
}
