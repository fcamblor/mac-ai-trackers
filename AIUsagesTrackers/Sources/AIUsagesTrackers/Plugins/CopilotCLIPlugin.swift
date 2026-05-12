import Foundation

/// GitHub Copilot CLI plugin namespace — see `ClaudeCodePlugin` for the
/// rationale on factory-style assembly.
public enum CopilotCLIPlugin {
    public static let branding = VendorBranding(
        vendor: .copilot,
        displayName: "GitHub Copilot CLI",
        tintHex: "6E40C9",
        assetName: "copilot-mark"
    )

    public static let documentation = VendorDocumentation(
        vendor: .copilot,
        slug: "copilot"
    )

    @discardableResult
    public static func register(
        connector: CopilotConnector,
        status: (any StatusConnector)? = CopilotStatusConnector(),
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
