import Foundation

/// Assembles and registers the Claude Desktop vendor bundle.
///
/// The connector is constructed by `AppDelegate` (not here) because its
/// `isEnabled` gate reads app preferences and its lifecycle is owned alongside
/// the poller — the plugin only wires branding, logging, sanitization, and the
/// documentation pointer, mirroring `ClaudeTUIPlugin`.
///
/// `status` is intentionally `nil`: Claude Desktop shares Anthropic's public
/// status page with the `claude` vendor, whose `ClaudeStatusConnector` already
/// surfaces those incidents. Duplicating them under a second vendor would double
/// every outage row. See `docs/vendors/claude-desktop.md`.
public enum ClaudeDesktopPlugin {
    public static let branding = VendorBranding(
        vendor: .claudeDesktop,
        displayName: "Claude Desktop",
        // Same orange mark and tint as the `claude` vendor — they are the same
        // product family; the display name is what distinguishes the rows.
        tintHex: "DA7756",
        assetName: "claude-mark"
    )
    public static let documentation = VendorDocumentation(vendor: .claudeDesktop, slug: "claude-desktop")

    @discardableResult
    public static func register(
        connector: ClaudeDesktopConnector,
        logger: FileLogger = Loggers.claudeDesktop,
        sanitizer: ClaudeDesktopPayloadSanitizer = ClaudeDesktopPayloadSanitizer()
    ) -> VendorBundle {
        let resolvedLogger = VerboseVendorMode.logger(for: .claudeDesktop, default: logger)
        let proxy = LoggingProxy(logger: resolvedLogger, sanitizer: sanitizer)
        let bundle = VendorBundle(
            vendor: .claudeDesktop,
            branding: branding,
            usage: connector,
            status: nil,
            activeAccountMonitor: nil,
            logger: resolvedLogger,
            loggingProxy: proxy,
            sanitizer: sanitizer,
            documentation: documentation
        )
        VendorRegistry.register(bundle)
        return bundle
    }
}
