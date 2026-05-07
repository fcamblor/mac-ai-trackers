import Foundation

/// GitHub Copilot CLI plugin namespace — see `ClaudeCodePlugin` for the
/// rationale on factory-style assembly. Copilot does not currently
/// expose a public statuspage we consume, so the bundle's `status`
/// stays optional with a `nil` default.
public enum CopilotCLIPlugin {
    public static let branding = VendorBranding(
        vendor: .copilot,
        displayName: "Copilot CLI",
        tintHex: "24292F",
        assetName: "copilot-mark"
    )

    public static let documentation = VendorDocumentation(
        vendor: .copilot,
        slug: "copilot"
    )

    @discardableResult
    public static func register(
        connector: CopilotConnector,
        status: (any StatusConnector)? = nil,
        monitor: CopilotActiveAccountMonitor? = nil,
        logger: FileLogger = Loggers.copilot,
        sanitizer: CopilotPayloadSanitizer = CopilotPayloadSanitizer()
    ) -> VendorBundle {
        let resolvedLogger = VerboseVendorMode.logger(for: .copilot, default: logger)
        let proxy = LoggingProxy(logger: resolvedLogger, sanitizer: sanitizer)
        let bundle = VendorBundle(
            vendor: .copilot,
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
