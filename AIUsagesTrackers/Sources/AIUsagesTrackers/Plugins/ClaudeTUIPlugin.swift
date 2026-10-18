import Foundation

/// Claude TUI (`claude` CLI) plugin namespace — assembles a `VendorBundle` from
/// pre-constructed sub-components and registers it with
/// `VendorRegistry`. The factory does not build the connectors itself
/// because the active-account monitor's callback typically references
/// the poller, which has the connector list as a dependency — running
/// those constructors here would create a cycle.
public enum ClaudeTUIPlugin {
    public static let branding = VendorBranding(
        vendor: .claudeTUI,
        displayName: "Claude TUI",
        tintHex: "DA7756",
        assetName: "claude-mark"
    )

    public static let documentation = VendorDocumentation(
        vendor: .claudeTUI,
        slug: "claude-tui"
    )

    @discardableResult
    public static func register(
        connector: ClaudeTUIConnector,
        status: ClaudeStatusConnector? = nil,
        monitor: ClaudeTUIActiveAccountMonitor? = nil,
        logger: FileLogger = Loggers.claudeTUI,
        sanitizer: ClaudeTUIPayloadSanitizer = ClaudeTUIPayloadSanitizer()
    ) -> VendorBundle {
        let resolvedLogger = VerboseVendorMode.logger(for: .claudeTUI, default: logger)
        let proxy = LoggingProxy(logger: resolvedLogger, sanitizer: sanitizer)
        let bundle = VendorBundle(
            vendor: .claudeTUI,
            branding: branding,
            usage: connector,
            status: status,
            activeAccountMonitor: monitor,
            logger: resolvedLogger,
            loggingProxy: proxy,
            sanitizer: sanitizer,
            documentation: documentation
        )
        VendorRegistry.register(bundle)
        return bundle
    }
}
