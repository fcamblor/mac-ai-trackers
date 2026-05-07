import Foundation

/// GitHub Copilot CLI plugin namespace — see `ClaudeCodePlugin` for the
/// rationale on factory-style assembly. Copilot does not currently
/// expose a public statuspage we consume, so the bundle's `status`
/// remains `nil`.
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
        session: URLSession = .shared,
        accountChangeCallback: (@Sendable (AccountEmail) async -> Void)? = nil
    ) -> VendorBundle {
        let logger = Loggers.copilot
        let sanitizer = CopilotPayloadSanitizer()
        let proxy = LoggingProxy(logger: logger, sanitizer: sanitizer)
        let connector = CopilotConnector(logger: logger, session: session)
        let monitor = CopilotActiveAccountMonitor(
            logger: logger,
            onActiveAccountChanged: accountChangeCallback
        )
        let bundle = VendorBundle(
            vendor: .copilot,
            branding: branding,
            usage: connector,
            status: nil,
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
