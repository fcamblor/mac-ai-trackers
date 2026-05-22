import SwiftUI
import AIUsagesTrackersLib

struct AssistantsSettingsView: View {
    let preferences: any AppPreferences

    var body: some View {
        Form {
            Section("Claude Code credentials") {
                KeychainDiagnosticView()
            }
        }
        .formStyle(.grouped)
    }
}

/// On-demand diagnostic that inspects the macOS Keychain entries written by
/// the `claude` CLI under "Claude Code-credentials" and lets the user pick
/// which entry the runtime should read from. The app never deletes or
/// modifies entries written by the vendor — picking an entry only updates a
/// local preference so the runtime can target it by `kSecAttrAccount`.
private struct KeychainDiagnosticView: View {
    @State private var phase: Phase = .idle
    @State private var selectedAccountTick: Int = 0

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
                Text("Running this scan may trigger a one-off macOS Keychain authorisation prompt. " +
                     "Approve it only if you want to run the diagnostic now — the app never " +
                     "inspects these entries on its own.")
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
        // Bind to the tick so picking from the result list re-renders this row.
        let _ = selectedAccountTick
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
            if selected != nil {
                Button("Clear", role: .destructive) {
                    preferences.claudeKeychainAccount = nil
                    selectedAccountTick &+= 1
                }
                .buttonStyle(.borderless)
            }
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
            ReportView(report: report, selectionTick: $selectedAccountTick)
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
                autoSelectValidEntry(in: report)
                phase = .success(report)
            } catch {
                phase = .failure(String(describing: error))
            }
        }
    }

    /// After the scan, point the runtime at the first entry that actually holds
    /// a `claudeAiOauth` block — expired tokens included, since the entry is
    /// still the right one to read after a `claude` CLI refresh. Skipped when
    /// the existing preference already matches a pinnable entry in this report
    /// — the user's explicit choice wins over the auto-pick.
    private func autoSelectValidEntry(in report: KeychainDiagnosticReport) {
        let pinnableEntries = report.entries.filter { entry in
            guard entry.account != nil else { return false }
            switch entry.status {
            case .validOAuthToken, .expiredOAuthToken: return true
            default: return false
            }
        }
        guard let firstPinnable = pinnableEntries.first, let firstPinnableAccount = firstPinnable.account else {
            return
        }
        let current = preferences.claudeKeychainAccount
        let currentIsPinnable = current != nil && pinnableEntries.contains { $0.account == current }
        guard !currentIsPinnable else { return }
        preferences.claudeKeychainAccount = firstPinnableAccount
        selectedAccountTick &+= 1
    }
}

private struct ReportView: View {
    let report: KeychainDiagnosticReport
    @Binding var selectionTick: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            headerBadge
            summaryLine
            if !report.entries.isEmpty {
                Divider()
                ForEach(Array(report.entries.enumerated()), id: \.offset) { _, entry in
                    EntryRow(entry: entry, selectionTick: $selectionTick)
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
                  subtitle: "Run the `claude` CLI to sign in.")
        } else if report.hasDuplicates {
            badge(systemImage: "exclamationmark.octagon.fill", color: .orange,
                  title: "Several entries found under the same service.",
                  subtitle: "The runtime has been pinned to the first entry that carries " +
                            "`claudeAiOauth.accessToken`. Use \"Use this entry\" below if you " +
                            "want to target a different one — entries without a usable token " +
                            "cannot be selected.")
        } else if report.hasUsableOAuthToken {
            badge(systemImage: "checkmark.seal.fill", color: .green,
                  title: "Claude Code credentials look healthy.",
                  subtitle: nil)
        } else if report.hasPinnableOAuthEntry {
            badge(systemImage: "clock.badge.exclamationmark.fill", color: .orange,
                  title: "Entry pinned, but its OAuth token has expired.",
                  subtitle: "Re-run the `claude` CLI to refresh the credentials in place — " +
                            "the runtime is already targeting this entry and will pick up the " +
                            "new token on the next refresh. No need to re-run the diagnostic.")
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
    @Binding var selectionTick: Int
    @State private var hovering = false

    private var preferences: any AppPreferences { AppDelegate.sharedPreferences }

    private var isSelected: Bool {
        let _ = selectionTick
        return entry.account != nil && preferences.claudeKeychainAccount == entry.account
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
                selectionTick &+= 1
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
