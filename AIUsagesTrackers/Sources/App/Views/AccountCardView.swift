import SwiftUI
import AIUsagesTrackersLib

/// Single-account card. Used for a group that has exactly one vendor member;
/// multi-vendor groups (same account signed into several vendors) render with
/// `AccountGroupCardView`.
struct AccountCardView: View {
    let entry: VendorUsageEntry
    let isRefreshing: Bool
    var onIgnore: (() -> Void)? = nil
    /// Surfaced for Claude rows whose last error points at the Keychain lookup —
    /// clicking it routes the user to the Coding Assistants settings tab where
    /// the duplicate-entry diagnostic can pick a specific `kSecAttrAccount`.
    var onOpenAssistantsSettings: (() -> Void)? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                VendorIconView(vendor: entry.vendor, size: 13)

                Text(entry.account.rawValue)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)

                if isRefreshing {
                    AccountCardSpinner()
                }

                Spacer()

                if entry.isActive {
                    ActiveCapsule()
                }
            }

            EntryBodyView(entry: entry, onOpenAssistantsSettings: onOpenAssistantsSettings)
        }
        .padding(10)
        .cardBackground(isActive: entry.isActive)
        .contextMenu {
            if let onIgnore {
                Button("Ignore this account") { onIgnore() }
            }
        }
    }
}

/// Merged card for an account present under several vendors (e.g. Claude Code
/// and Claude Desktop). The shared account email is shown once; each vendor is a
/// labelled sub-section with its own active state, metrics, and errors.
struct AccountGroupCardView: View {
    let group: AccountDisplayGroup
    var isRefreshing: (VendorUsageEntry) -> Bool
    var onIgnoreMember: (VendorUsageEntry) -> Void
    var onOpenAssistantsSettings: (() -> Void)? = nil

    private var anyRefreshing: Bool { group.members.contains(where: isRefreshing) }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Text(group.account.rawValue)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .truncationMode(.middle)

                if anyRefreshing {
                    AccountCardSpinner()
                }

                Spacer()

                if group.isActive {
                    ActiveCapsule()
                }
            }

            ForEach(Array(group.members.enumerated()), id: \.offset) { _, member in
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 6) {
                        VendorIconView(vendor: member.vendor, size: 13)
                        Text(vendorDisplayName(member.vendor))
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(.secondary)
                        Spacer()
                        if member.isActive {
                            ActiveCapsule()
                        }
                    }
                    EntryBodyView(entry: member, onOpenAssistantsSettings: onOpenAssistantsSettings)
                }
                .padding(8)
                .background(
                    member.isActive ? Color.green.opacity(0.12) : Color.primary.opacity(0.04),
                    in: RoundedRectangle(cornerRadius: 6)
                )
                .contextMenu {
                    Button("Ignore this account") { onIgnoreMember(member) }
                }
            }
        }
        .padding(10)
        .cardBackground(isActive: group.isActive)
    }

    private func vendorDisplayName(_ vendor: Vendor) -> String {
        VendorRegistry.bundle(for: vendor)?.branding.displayName ?? vendor.rawValue
    }
}

// MARK: - Shared pieces

private struct AccountCardSpinner: View {
    var body: some View {
        ProgressView()
            .controlSize(.small)
            .scaleEffect(0.6)
            .frame(width: 12, height: 12)
    }
}

private struct ActiveCapsule: View {
    var body: some View {
        Text("active")
            .font(.system(size: 9, weight: .medium))
            .foregroundStyle(.white)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Color.green, in: Capsule())
    }
}

private extension View {
    func cardBackground(isActive: Bool) -> some View {
        self
            .background(
                isActive
                    ? Color.green.opacity(0.20)
                    : Color(NSColor.controlBackgroundColor),
                in: RoundedRectangle(cornerRadius: 8)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(Color.primary.opacity(0.20), lineWidth: 1)
            )
    }
}

/// The metrics list + error block for one entry, shared by the single-account
/// card and each sub-section of the merged group card.
struct EntryBodyView: View {
    let entry: VendorUsageEntry
    var onOpenAssistantsSettings: (() -> Void)? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(entry.metrics.enumerated()), id: \.offset) { _, metric in
                metricRow(for: metric)
            }
            if let lastError = entry.lastError {
                errorRow(for: lastError)
            }
        }
    }

    @ViewBuilder
    private func metricRow(for metric: UsageMetric) -> some View {
        switch metric {
        case let .timeWindow(name, resetAt, windowDuration, usagePercent):
            TimeWindowMetricRow(
                name: name,
                resetAt: resetAt,
                windowDuration: windowDuration,
                usagePercent: usagePercent
            )
        case let .payAsYouGo(name, currentAmount, currency):
            PayAsYouGoMetricRow(
                name: name,
                currentAmount: currentAmount,
                currency: currency
            )
        case .unknown:
            EmptyView()
        }
    }

    private func errorRow(for error: UsageError) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top, spacing: 6) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.orange)
                    .frame(width: 12, height: 12)

                VStack(alignment: .leading, spacing: 2) {
                    Text(errorTitle(for: error.type))
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.primary)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(errorDetail(for: error.type, vendor: entry.vendor))
                        .font(.system(size: 9))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            if showsAssistantsCTA(for: error.type), let onOpenAssistantsSettings {
                Button {
                    onOpenAssistantsSettings()
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "stethoscope")
                            .font(.system(size: 9, weight: .semibold))
                        Text("Open Coding Assistants diagnostic")
                            .font(.system(size: 9, weight: .semibold))
                    }
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.orange)
            }
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 6))
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .strokeBorder(Color.orange.opacity(0.35), lineWidth: 1)
        )
    }

    /// Only Claude rows benefit from the diagnostic — the same error types on
    /// Codex/Copilot would route to the wrong panel.
    private func showsAssistantsCTA(for type: String) -> Bool {
        guard entry.vendor == .claude else { return false }
        switch type {
        case "token_error", "credential_error", "api_key_usage_unsupported":
            return true
        case "token_expired":
            // Re-running the diagnostic on an expired token wouldn't help — the
            // entry is already pinned and the only fix is `claude` CLI refresh.
            return false
        default:
            return false
        }
    }

    private func errorTitle(for type: String) -> String {
        switch type {
        case "api_key_usage_unsupported":
            "Usage unavailable with API key auth"
        case "token_error":
            "Authentication unavailable"
        case "credential_error":
            "Credential lookup failed"
        case "token_expired":
            "Session expired"
        case "api_error":
            "Usage refresh failed"
        case "parse_error":
            "Unexpected usage response"
        case "account_unknown":
            "Account not detected"
        case "http_429":
            "Usage refresh rate-limited"
        default:
            if type.hasPrefix("http_") {
                "Usage refresh failed"
            } else {
                "Usage issue"
            }
        }
    }

    private func errorDetail(for type: String, vendor: Vendor) -> String {
        switch type {
        case "api_key_usage_unsupported":
            "Claude standard API keys cannot expose usage here. Claude Code OAuth credentials are required."
        case "token_error":
            "No usable local credentials were found."
        case "credential_error":
            "Credentials could not be read from the expected local source. Last known metrics may be stale."
        case "token_expired":
            tokenExpiredDetail(for: vendor)
        case "api_error":
            "Network or API request failed. Last known metrics may be stale."
        case "parse_error":
            "The vendor response shape changed or was incomplete."
        case "account_unknown":
            "The active local account could not be resolved."
        case "http_429":
            "The vendor is throttling usage refreshes. Last known metrics are kept."
        default:
            if type.hasPrefix("http_") {
                "Vendor returned \(type.replacingOccurrences(of: "http_", with: "HTTP "))."
            } else {
                "Connector reported \(type)."
            }
        }
    }

    private func tokenExpiredDetail(for vendor: Vendor) -> String {
        switch vendor {
        case .claude:
            "Your Claude Code session has expired. Run \"/login\" in the Claude Code CLI to re-authenticate — the next refresh will pick up the new token."
        case .claudeDesktop:
            "This Claude Desktop profile's session has expired. Open Claude Desktop for that profile to refresh — the next refresh will pick up the new token."
        case .copilot:
            "Your GitHub Copilot session has expired. Run \"gh auth login\" in a terminal to re-authenticate — the next refresh will pick up the new token."
        case .codex:
            "Your Codex session has expired. Run \"codex login\" in a terminal to re-authenticate — the next refresh will pick up the new token."
        default:
            "Your session has expired. Re-authenticate with the vendor CLI — the next refresh will pick up the new token."
        }
    }
}
