import Foundation

/// Google Antigravity plugin namespace — see `ClaudeCodePlugin` for the
/// rationale on factory-style assembly.
public enum AntigravityPlugin {
    public static let branding = VendorBranding(
        vendor: .antigravity,
        displayName: "Google Antigravity",
        tintHex: "4285F4",
        assetName: "antigravity-mark"
    )

    public static let documentation = VendorDocumentation(
        vendor: .antigravity,
        slug: "antigravity"
    )

    @discardableResult
    public static func register(
        connector: AntigravityConnector,
        status: (any StatusConnector)? = nil,
        monitor: (any ActiveAccountMonitoring)? = nil,
        logger: FileLogger = Loggers.antigravity,
        sanitizer: AntigravityPayloadSanitizer = AntigravityPayloadSanitizer()
    ) -> VendorBundle {
        let resolvedLogger = VerboseVendorMode.logger(for: .antigravity, default: logger)
        let proxy = LoggingProxy(logger: resolvedLogger, sanitizer: sanitizer)
        let bundle = VendorBundle(
            vendor: .antigravity,
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
