import SwiftUI
import AIUsagesTrackersLib

/// One-shot "what changed for you" window shown after `StorageSchemaMigration`
/// upgraded a pre-0.8 install. Never shown on a fresh install.
struct UpgradeChangelogView: View {
    let version: String
    let onOpenAssistantsSettings: () -> Void
    let onDismiss: () -> Void

    private static let width: CGFloat = 520
    private static let bodyHeight: CGFloat = 420

    /// Custom-scheme link intercepted in-app to open the profile how-to sheet
    /// instead of handing the URL to the system.
    private static let profileHelpURL = URL(string: "ai-usages-tracker://claude-desktop-custom-profile")! // known-valid literal

    static let markdown = """
    ## Claude Desktop support
    - AI Usages Tracker can now also read usage from the **Claude Desktop** app, including several profiles (`--user-data-dir`) - [how to add a custom profile](\(profileHelpURL.absoluteString)).
    - It is **off by default**: enable it in *Settings › Coding Assistants*. macOS will ask once for access to the `Claude Safe Storage` Keychain entry - only when you turn it on.

    ## One card per Claude account
    - When the same Anthropic account is signed in to both Claude Code (CLI) and Claude Desktop, the popover shows **a single merged card** with one chip per source, and the usage of both sources is merged.
    - Claude Desktop profiles are always considered active, so the highlight is not shown for them. As soon as a Claude Desktop account is set up, its usage stays up to date even when Claude Code is signed in to another account.
    - **"Currently active"** selections (menu bar chips, charts) follow the **Claude Code CLI (TUI)** account only and no longer target Claude Desktop. A selection pinned to a **specific account** covers both its Claude Code and Claude Desktop sources.
    - Menu bar chip and chart pickers list a single **Claude** vendor covering both sources.

    ## Your settings were migrated
    - Claude accounts you had ignored stay hidden for their Claude Desktop source too.
    - Your custom account order is preserved; Claude Desktop sources sit with their Claude Code account.
    - Existing menu bar chips and charts keep working unchanged.

    Frédéric
    """

    static let profileHelpMarkdown = """
    ## Add a custom Claude Desktop profile
    1. Create an empty folder wherever you like:
    ```
    mkdir -p "$HOME/path/to/claude-profiles/personal"
    ```
    2. Open Claude Desktop with this folder as its user data directory:
    ```
    open -n -a ~/Applications/Claude.app --args --user-data-dir="$HOME/path/to/claude-profiles/personal"
    ```
    3. When signing in through the browser, make sure **no other Claude Desktop window** is open besides this profile's one, so the sign-in redirect opens - and authenticates - this profile.
    4. Declare `$HOME/path/to/claude-profiles/personal` with **Add profile folder…** in *Settings › Coding Assistants*.
    """

    @State private var isShowingProfileHelp = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "sparkles")
                    .foregroundStyle(.tint)
                VStack(alignment: .leading, spacing: 2) {
                    Text("What's new in AI Usages Tracker \(version)")
                        .font(.system(size: 13, weight: .semibold))
                    Text("Your data has been upgraded - here is what changes for you.")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            }
            Divider()
            ScrollView(.vertical, showsIndicators: true) {
                ReleaseNotesMarkdownView(markdown: Self.markdown)
                    .padding(16)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .environment(\.openURL, OpenURLAction { url in
                guard url == Self.profileHelpURL else { return .systemAction }
                isShowingProfileHelp = true
                return .handled
            })
            // A fixed height: a ScrollView has no intrinsic height, so with only a
            // max it collapses to zero when the window sizes itself to fit.
            .frame(height: Self.bodyHeight)
            .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
            Divider()
            HStack {
                Button("Set up Claude Desktop…") { onOpenAssistantsSettings() }
                    .buttonStyle(.borderless)
                Spacer()
                Button("Got it") { onDismiss() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(16)
        .frame(width: Self.width)
        .sheet(isPresented: $isShowingProfileHelp) {
            VStack(alignment: .leading, spacing: 12) {
                ReleaseNotesMarkdownView(markdown: Self.profileHelpMarkdown)
                    .textSelection(.enabled)
                HStack {
                    Spacer()
                    Button("Close") { isShowingProfileHelp = false }
                        .keyboardShortcut(.defaultAction)
                }
            }
            .padding(16)
            .frame(width: Self.width - Self.profileHelpInset)
        }
    }

    private static let profileHelpInset: CGFloat = 40
}
