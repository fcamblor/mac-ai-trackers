import Foundation

/// Codex (ChatGPT) plugin namespace — see `ClaudeCodePlugin` for the
/// rationale on factory-style assembly with pre-built sub-components.
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

    @discardableResult
    public static func register(
        connector: CodexConnector,
        status: CodexStatusConnector? = nil,
        monitor: CodexActiveAccountMonitor? = nil,
        logger: FileLogger = Loggers.codex,
        sanitizer: CodexPayloadSanitizer = CodexPayloadSanitizer()
    ) -> VendorBundle {
        let proxy = LoggingProxy(logger: logger, sanitizer: sanitizer)
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
