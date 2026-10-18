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
            Section("Claude TUI credentials") {
                KeychainDiagnosticView()
            }
            Section("Claude Desktop") {
                ClaudeDesktopSection()
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
            // Group ignored sources by account family + email so a merged Claude
            // account shows once; the trash button un-ignores all of its sources.
            ForEach(ignoredGroups, id: \.key) { ignoredGroup in
                HStack(spacing: 8) {
                    HStack(spacing: 2) {
                        ForEach(ignoredGroup.members, id: \.self) { member in
                            VendorIconView(vendor: member.vendor, size: 13)
                        }
                    }
                    Text(ignoredGroup.account.rawValue)
                        .font(.system(size: 12))
                    Spacer()
                    Button(role: .destructive) {
                        let members = Set(ignoredGroup.members)
                        prefs.ignoredAccounts.removeAll { members.contains($0) }
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

    private struct IgnoredGroup {
        let key: String
        let account: AccountEmail
        let members: [IgnoredAccount]
    }

    private var ignoredGroups: [IgnoredGroup] {
        var order: [String] = []
        var byKey: [String: [IgnoredAccount]] = [:]
        for ignored in prefs.ignoredAccounts {
            let key = "\(ignored.vendor.accountFamily)\u{0000}\(ignored.account.rawValue)"
            if byKey[key] == nil { order.append(key) }
            byKey[key, default: []].append(ignored)
        }
        return order.compactMap { key in
            guard let members = byKey[key], let first = members.first else { return nil }
            return IgnoredGroup(key: key, account: first.account, members: members)
        }
    }
}

// MARK: - Claude Desktop section

/// Enables the Claude Desktop usage source and manages the extra profile
/// directories opened via `--user-data-dir`. Enabling the source is the explicit
/// user action that authorises the one-time `Claude Safe Storage` Keychain
/// prompt the connector needs (see `docs/vendors/claude-desktop.md`).
private struct ClaudeDesktopSection: View {
    private var prefs: UserDefaultsAppPreferences { AppDelegate.sharedPreferences }
    @State private var isShowingProfileHelp = false

    var body: some View {
        Toggle(isOn: Binding(
            get: { prefs.claudeDesktopEnabled },
            set: { prefs.claudeDesktopEnabled = $0 }
        )) {
            Text("Show usage from Claude Desktop profiles")
        }
        Text("Reads per-profile usage from the local Claude Desktop app. The first refresh asks macOS to allow reading the “Claude Safe Storage” keychain item — approve it once. The two standard profiles are detected automatically; add custom folders below if you launch Claude Desktop with a custom --user-data-dir.")
            .font(.caption)
            .foregroundStyle(.secondary)

        if prefs.claudeDesktopProfilePaths.isEmpty {
            Text("No custom profile folders.")
                .foregroundStyle(.secondary)
        } else {
            ForEach(prefs.claudeDesktopProfilePaths, id: \.self) { path in
                HStack(spacing: 8) {
                    Image(systemName: "folder")
                    Text((path as NSString).abbreviatingWithTildeInPath)
                        .font(.system(size: 12))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer()
                    Button(role: .destructive) {
                        prefs.claudeDesktopProfilePaths.removeAll { $0 == path }
                    } label: {
                        Image(systemName: "trash")
                    }
                    .buttonStyle(.borderless)
                }
            }
        }

        HStack {
            Button("Add profile folder…") {
                addProfileFolder()
            }
            Spacer()
            Button("How to run several Claude Desktop accounts…") {
                isShowingProfileHelp = true
            }
            .buttonStyle(.link)
        }
        .sheet(isPresented: $isShowingProfileHelp) {
            ClaudeDesktopProfileHelpSheet { isShowingProfileHelp = false }
        }
    }

    private func addProfileFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Add"
        panel.message = "Choose a Claude Desktop --user-data-dir profile folder"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let path = url.path
        if !prefs.claudeDesktopProfilePaths.contains(path) {
            prefs.claudeDesktopProfilePaths.append(path)
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

    /// Accounts are listed and reordered as merged groups (Claude CLI + Claude
    /// Desktop collapse into one row), keyed by the group id (`family:email`).
    private var visibleGroups: [AccountDisplayGroup] {
        store.entries
            .excluding(ignoredAccounts: prefs.ignoredAccounts)
            .groupedForDisplay(order: prefs.accountsOrder)
    }

    var body: some View {
        let groups = visibleGroups
        if groups.isEmpty {
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
                        ForEach(groups, id: \.id) { group in
                            row(for: group)
                        }
                    }
                    .animation(.spring(response: 0.34, dampingFraction: 0.85), value: draggingID)
                    .animation(.spring(response: 0.34, dampingFraction: 0.85), value: dropIndex)
                    dropIndicator(groups: groups)
                    floatingPreview(groups: groups)
                }
                .coordinateSpace(name: Self.coordinateSpaceName)
                .onPreferenceChange(AccountRowFramePreferenceKey.self) { rowFrames = $0 }
            }
        }
    }

    private func row(for group: AccountDisplayGroup) -> some View {
        let isDragging = draggingID == group.id
        return AccountOrderingRow(
            group: group,
            isBeingDragged: isDragging,
            dragCoordinateSpace: Self.coordinateSpaceName,
            onIgnore: { ignore(group: group) },
            onDragChanged: { value in handleDragChanged(value: value, groupID: group.id) },
            onDragEnded: { value in handleDragEnded(value: value, groupID: group.id) }
        )
        .background(
            GeometryReader { geo in
                Color.clear.preference(
                    key: AccountRowFramePreferenceKey.self,
                    value: [group.id: geo.frame(in: .named(Self.coordinateSpaceName))]
                )
            }
        )
        .opacity(isDragging ? 0.0 : 1.0)
        .frame(maxHeight: isDragging ? 0 : nil)
        .clipped()
    }

    @ViewBuilder
    private func dropIndicator(groups: [AccountDisplayGroup]) -> some View {
        if let dropIndex, let y = dropIndicatorY(groups: groups, atIndex: dropIndex) {
            Capsule()
                .fill(Color.accentColor)
                .frame(height: 2)
                .padding(.horizontal, 4)
                .offset(y: y - 1)
                .allowsHitTesting(false)
        }
    }

    private func dropIndicatorY(groups: [AccountDisplayGroup], atIndex index: Int) -> CGFloat? {
        let visible = groups.filter { $0.id != draggingID }
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
    private func floatingPreview(groups: [AccountDisplayGroup]) -> some View {
        if let id = draggingID,
           let group = groups.first(where: { $0.id == id }),
           let frame = rowFrames[id] {
            AccountListFloatingDragPreview(
                tracker: cursorTracker,
                group: group,
                frame: frame
            )
        }
    }

    private func handleDragChanged(value: DragGesture.Value, groupID: String) {
        if draggingID == nil {
            draggingID = groupID
        }
        cursorTracker.y = value.location.y
        let newDropIndex = computeDropIndex(at: value.location.y, groups: visibleGroups)
        if newDropIndex != dropIndex {
            dropIndex = newDropIndex
        }
    }

    private func handleDragEnded(value: DragGesture.Value, groupID: String) {
        let groups = visibleGroups
        let finalIndex = computeDropIndex(at: value.location.y, groups: groups)
        performDrop(draggedID: groupID, toVisibleIndex: finalIndex, groups: groups)
        withAnimation(.spring(response: 0.34, dampingFraction: 0.82)) {
            draggingID = nil
            dropIndex = nil
        }
    }

    private func computeDropIndex(at y: CGFloat, groups: [AccountDisplayGroup]) -> Int {
        let visible = groups.filter { $0.id != draggingID }
        for (idx, group) in visible.enumerated() {
            guard let frame = rowFrames[group.id] else { continue }
            if y < frame.midY { return idx }
        }
        return visible.count
    }

    private func performDrop(draggedID: String, toVisibleIndex visibleIndex: Int, groups: [AccountDisplayGroup]) {
        var ordered = groups
        guard let sourceIdx = ordered.firstIndex(where: { $0.id == draggedID }) else { return }
        let destOffset: Int
        if visibleIndex >= sourceIdx {
            destOffset = visibleIndex + 1
        } else {
            destOffset = visibleIndex
        }
        if destOffset == sourceIdx || destOffset == sourceIdx + 1 { return }
        ordered.move(fromOffsets: IndexSet(integer: sourceIdx), toOffset: destOffset)
        // Persist as the flat list of member entry ids in the new group order —
        // `sortedForDisplay`/`groupedForDisplay` key on entry ids, so writing a
        // group's members consecutively keeps that group in place.
        prefs.accountsOrder = ordered.flatMap { $0.members.map(\.id) }
    }

    private func ignore(group: AccountDisplayGroup) {
        // From Settings, ignoring a merged account hides all of its auth sources.
        for member in group.members {
            let ignored = IgnoredAccount(vendor: member.vendor, account: member.account)
            if !prefs.ignoredAccounts.contains(ignored) {
                prefs.ignoredAccounts.append(ignored)
            }
        }
    }
}

private struct AccountOrderingRow: View {
    let group: AccountDisplayGroup
    let isBeingDragged: Bool
    let dragCoordinateSpace: String
    let onIgnore: () -> Void
    let onDragChanged: (DragGesture.Value) -> Void
    let onDragEnded: (DragGesture.Value) -> Void

    @State private var isHovering = false

    var body: some View {
        HStack(spacing: 8) {
            dragHandle
            AccountGroupVendorIcons(members: group.members)
            Text(group.account.rawValue)
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
    let group: AccountDisplayGroup

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "line.3.horizontal")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 18, height: 22)
            AccountGroupVendorIcons(members: group.members)
            Text(group.account.rawValue)
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
    let group: AccountDisplayGroup
    let frame: CGRect

    var body: some View {
        AccountDragPreviewCard(group: group)
            .frame(width: max(frame.width, 240))
            .offset(x: frame.minX, y: tracker.y - frame.height / 2)
            .allowsHitTesting(false)
    }
}

/// A single family icon followed by one chip per auth source (tui / desktop),
/// so the ordering/ignored rows read like the popover's merged card without
/// repeating the vendor icon.
private struct AccountGroupVendorIcons: View {
    let members: [VendorUsageEntry]

    private var familyVendor: Vendor {
        members.first?.vendor.familyCanonicalVendor ?? .claude
    }

    private var sources: [(vendor: Vendor, isActive: Bool)] {
        var seen = Set<String>()
        return members
            .filter { seen.insert($0.vendor.rawValue).inserted }
            .map { ($0.vendor, $0.isActive) }
    }

    var body: some View {
        HStack(spacing: 4) {
            VendorIconView(vendor: familyVendor, size: 13)
            ForEach(sources, id: \.vendor.rawValue) { source in
                AuthSourceChip(label: authSourceLabel(for: source.vendor), isActive: source.isActive)
            }
        }
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
    private let credentialsService = ClaudeTUICredentialLocator.defaultKeychainService
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
                         "Usage metrics require Claude TUI OAuth credentials — sign in with " +
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
                  title: "Claude TUI credentials look healthy.",
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
