import Foundation

enum CopilotConstants {
    static let requestTimeoutSeconds: TimeInterval = 5

    /// Headers the gh-copilot client sends along — required, otherwise the
    /// `copilot_internal/user` endpoint returns 401/403 even with a valid token.
    static let editorVersion = "vscode/1.96.2"
    static let editorPluginVersion = "copilot-chat/0.26.7"
    static let userAgent = "GithubCopilotChat/0.26.7"
    static let apiVersion = "2025-04-01"
}
