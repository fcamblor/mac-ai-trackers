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

    static let markdown = """
    ## Claude Desktop support
    - AI Usages Tracker can now also read usage from the **Claude Desktop** app, including several profiles (`--user-data-dir`).
    - It is **off by default**: enable it in *Settings › Coding Assistants*. macOS will ask once for access to the `Claude Safe Storage` Keychain entry — only when you turn it on.

    ## One card per Claude account
    - When the same Anthropic account is signed in to both Claude Code (CLI) and Claude Desktop, the popover shows **a single merged card** with one chip per source.
    - The "active" highlight and **"Currently active"** selections (menu bar chips, charts) now follow the **Claude Code CLI (TUI)** account only — Desktop profiles never change it.
    - Menu bar chip and chart pickers list a single **Claude** vendor covering both sources.

    ## Your settings were migrated
    - Claude accounts you had ignored stay hidden for their Claude Desktop source too.
    - Your custom account order is preserved; Claude Desktop sources sit with their Claude Code account.
    - Existing menu bar chips and charts keep working unchanged.
    """

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "sparkles")
                    .foregroundStyle(.tint)
                VStack(alignment: .leading, spacing: 2) {
                    Text("What's new in AI Usages Tracker \(version)")
                        .font(.system(size: 13, weight: .semibold))
                    Text("Your data has been upgraded — here is what changes for you.")
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
    }
}
