import Foundation

/// Claude Code plugin namespace — assembles a `VendorBundle` from
/// pre-constructed sub-components and registers it with
/// `VendorRegistry`. The factory does not build the connectors itself
/// because the active-account monitor's callback typically references
/// the poller, which has the connector list as a dependency — running
/// those constructors here would create a cycle.
public enum ClaudeCodePlugin {
    public static let branding = VendorBranding(
        vendor: .claude,
        displayName: "Claude Code",
        tintHex: "DA7756",
        assetName: "claude-mark"
    )

    public static let documentation = VendorDocumentation(
        vendor: .claude,
        slug: "claude"
    )

    @discardableResult
    public static func register(
        connector: ClaudeCodeConnector,
        status: ClaudeStatusConnector? = nil,
        monitor: ClaudeActiveAccountMonitor? = nil,
        logger: FileLogger = Loggers.claude,
        sanitizer: ClaudePayloadSanitizer = ClaudePayloadSanitizer()
    ) -> VendorBundle {
        let proxy = LoggingProxy(logger: logger, sanitizer: sanitizer)
        let bundle = VendorBundle(
            vendor: .claude,
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
