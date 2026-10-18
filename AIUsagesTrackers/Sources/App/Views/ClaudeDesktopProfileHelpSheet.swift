import SwiftUI

/// Step-by-step guide for running an extra Claude Desktop instance on its own
/// `--user-data-dir`, shared by the upgrade changelog and the Coding Assistants
/// settings so both always show the same instructions.
struct ClaudeDesktopProfileHelpSheet: View {
    let onClose: () -> Void

    private static let width: CGFloat = 480

    static let markdown = """
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

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ReleaseNotesMarkdownView(markdown: Self.markdown)
                .textSelection(.enabled)
            HStack {
                Spacer()
                Button("Close") { onClose() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(16)
        .frame(width: Self.width)
    }
}
