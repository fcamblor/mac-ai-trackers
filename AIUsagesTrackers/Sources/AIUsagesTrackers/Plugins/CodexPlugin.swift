import Foundation

/// Codex (ChatGPT) plugin namespace — see `ClaudeCodePlugin` for the
/// rationale on factory-style assembly.
public enum CodexPlugin {
    public static let branding = VendorBranding(
        vendor: .codex,
        displayName: "Codex",
        tintHex: "10A37F",
        assetName: "codex-mark"
    )

    public static let documentation = VendorDocumentation(
        vendor: .codex,
        slug: "codex"
    )

    /// Builds and registers a `VendorBundle` for Codex. The
    /// `accountChangeCallback` runs on the cooperative thread pool when
    /// the active Codex account changes — typically a closure that
    /// invalidates the connector's email cache and forces a poll.
    @discardableResult
    public static func register(
        session: URLSession = .shared,
        accountChangeCallback: (@Sendable (AccountId) async -> Void)? = nil
    ) -> VendorBundle {
        let logger = Loggers.codex
        let sanitizer = CodexPayloadSanitizer()
        let proxy = LoggingProxy(logger: logger, sanitizer: sanitizer)
        let connector = CodexConnector(logger: logger, session: session)
        let status = CodexStatusConnector(logger: logger, session: session)
        let monitor = CodexActiveAccountMonitor(
            logger: logger,
            onActiveAccountChanged: accountChangeCallback
        )
        let bundle = VendorBundle(
            vendor: .codex,
            branding: branding,
            usage: connector,
            status: status,
            activeAccountMonitor: monitor,
            logger: logger,
            loggingProxy: proxy,
            sanitizer: sanitizer,
            documentation: documentation
        )
        VendorRegistry.register(bundle)
        return bundle
    }
}
