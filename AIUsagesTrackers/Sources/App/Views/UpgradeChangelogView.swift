import SwiftUI
import AIUsagesTrackersLib

/// "What changed for you" window. Opened automatically once after
/// `StorageSchemaMigration` upgraded an older install (never on a fresh
/// install), and on demand from the Updates settings tab. A compact version
/// picker gives access to older entries without listing them all.
struct UpgradeChangelogView: View {
    let onOpenAssistantsSettings: () -> Void
    let onDismiss: () -> Void
    @State private var selectedVersion: String

    init(
        initialVersion: String?,
        onOpenAssistantsSettings: @escaping () -> Void,
        onDismiss: @escaping () -> Void
    ) {
        self.onOpenAssistantsSettings = onOpenAssistantsSettings
        self.onDismiss = onDismiss
        _selectedVersion = State(initialValue: WhatsNewCatalog.entry(for: initialVersion).version)
    }

    private var entry: WhatsNewEntry { WhatsNewCatalog.entry(for: selectedVersion) }

    private static let width: CGFloat = 680
    private static let bodyHeight: CGFloat = 600



    @State private var isShowingProfileHelp = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "sparkles")
                    .foregroundStyle(.tint)
                VStack(alignment: .leading, spacing: 2) {
                    Text("What's new in AI Usages Tracker \(entry.version)")
                        .font(.system(size: 13, weight: .semibold))
                    Text("Here is what changes for you in this release.")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if WhatsNewCatalog.entries.count > 1 {
                    Picker("Version", selection: $selectedVersion) {
                        ForEach(WhatsNewCatalog.entries, id: \.version) { entry in
                            Text(entry.version).tag(entry.version)
                        }
                    }
                    .pickerStyle(.menu)
                    .labelsHidden()
                    .fixedSize()
                }
            }
            Divider()
            ScrollView(.vertical, showsIndicators: true) {
                ReleaseNotesMarkdownView(markdown: entry.markdown)
                    .padding(16)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .environment(\.openURL, OpenURLAction { url in
                guard url == WhatsNewCatalog.profileHelpURL else { return .systemAction }
                isShowingProfileHelp = true
                return .handled
            })
            // A fixed height: a ScrollView has no intrinsic height, so with only a
            // max it collapses to zero when the window sizes itself to fit.
            .frame(height: Self.bodyHeight)
            .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
            Divider()
            HStack {
                if entry.offersClaudeDesktopSetup {
                    Button("Set up Claude Desktop…") { onOpenAssistantsSettings() }
                        .buttonStyle(.borderless)
                }
                Spacer()
                Button("Got it") { onDismiss() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(16)
        .frame(width: Self.width)
        .sheet(isPresented: $isShowingProfileHelp) {
            ClaudeDesktopProfileHelpSheet { isShowingProfileHelp = false }
        }
    }
}

struct WhatsNewEntry: Sendable {
    let version: String
    let markdown: String
    let offersClaudeDesktopSetup: Bool
}

/// Every release that ships a "What's new" note, newest first. Add new
/// entries at the top; older ones stay reachable through the version picker.
enum WhatsNewCatalog {
    /// Custom-scheme link intercepted in-app to open the profile how-to sheet
    /// instead of handing the URL to the system.
    static let profileHelpURL = URL(string: "ai-usages-tracker://claude-desktop-custom-profile")! // known-valid literal

    static let entries: [WhatsNewEntry] = [
        WhatsNewEntry(version: "0.8.0", markdown: v0_8_0, offersClaudeDesktopSetup: true),
    ]

    /// Falls back to the newest entry when `version` is nil or unknown (e.g. a
    /// pending flag written by a build whose note was later removed).
    static func entry(for version: String?) -> WhatsNewEntry {
        // `entries` is a non-empty literal, so `first` always exists.
        entries.first { $0.version == version } ?? entries[0]
    }

    private static let v0_8_0 = """
    ## Claude Desktop support
    - AI Usages Tracker can now also read usage from the **Claude Desktop** app, including several profiles (`--user-data-dir`) - [how to add a custom profile](\(profileHelpURL.absoluteString)).
    - It is **off by default**: enable it in *Settings › Coding Assistants*. macOS will ask once for access to the `Claude Safe Storage` Keychain entry - only when you turn it on.

    ## One card per Claude account
    - When the same Anthropic account is signed in to both the Claude TUI (CLI) and Claude Desktop, the popover shows **a single merged card** with one chip per source, and the usage of both sources is merged.
    - Claude Desktop profiles are always considered active, so the highlight is not shown for them. As soon as a Claude Desktop account is set up, its usage stays up to date even when the Claude TUI is signed in to another account - but only while its Claude Desktop token is valid. AI Usages Tracker never refreshes it itself (it never alters an assistant's configuration or sessions), so open Claude Desktop from time to time to keep that profile's token fresh.
    - **"Currently active"** selections (menu bar chips, charts) follow the **Claude TUI (CLI)** account only and no longer target Claude Desktop. A selection pinned to a **specific account** covers both its Claude TUI and Claude Desktop sources.
    - ⚠️ **Behaviour change:** once Claude Desktop tracking is enabled, every Desktop profile keeps its usage up to date on its own, so which account is "active" matters much less than before. Consider replacing **"Currently active"** with a **specific account** in your menu bar chips and charts.
    - Menu bar chip and chart pickers list a single **Claude** vendor covering both sources.

    ## Codex: richer account status
    - When Codex refuses requests, the card says so with a **"Usage limit reached · resumes at HH:MM"** banner instead of a bare 100 % gauge, and the matching menu bar chip shows **⏸ HH:MM**. An admin **spending cap** gets its own banner.
    - The card header shows your **plan** (Plus, Pro, Pro Lite, Team…) and how many **usage limit resets** you have left - hover it to see when each one expires.
    - **Unavailable models** are listed with the time they come back, and whether buying credits would unlock them.
    - Accounts with credits show the **remaining balance** and an estimate of the **messages left**, locally and in the cloud.
    - Fixed: on Pro and Pro Lite plans, the weekly limit was labelled **"Session (5h)"**. ⚠️ If a menu bar chip or chart pointed at that metric, re-select **"Weekly (7d)"**. Likewise, **"Credits used"** became **"Credits balance"** and now shows the real remaining balance.

    ## Plans for every assistant
    - **Claude** and **Copilot** cards show your plan too (Pro, Max 5x, Max 20x, Team Standard / Premium, Enterprise / Free, Pro, Business…).
    - The Codex reset counter turns **orange** when a reset expires within 3 days, so you don't lose it unused.

    ## Choose the metrics shown in the popover
    - Hide rows you don't need, per assistant, in *Settings › Coding Assistants › Popover metrics* - for example Claude's **Weekly share** rows, or Codex's **Credits balance** / **Messages left**.
    - Hidden metrics keep working in menu bar chips and charts.

    ## Your settings were migrated
    - Claude accounts you had ignored stay hidden for their Claude Desktop source too.
    - Your custom account order is preserved; Claude Desktop sources sit with their Claude TUI account.
    - Existing menu bar chips and charts keep working unchanged.
    - A copy of your pre-0.8 data was saved. Should you need to go back to 0.7.x, restore it first from *Settings › Updates › Advanced*.

    Frédéric
    """
}
