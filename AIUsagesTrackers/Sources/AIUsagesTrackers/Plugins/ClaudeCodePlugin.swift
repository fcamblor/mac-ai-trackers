import Foundation

/// Claude Code plugin namespace — assembles the `VendorBundle` from the
/// vendor-specific connector, status connector, active-account monitor,
/// and sanitizer. The bundle is constructed by `AppDelegate` (not at
/// module-load time) because the active-account monitor needs a
/// poller-aware callback that doesn't exist until startup is past
/// `applicationDidFinishLaunching`'s wiring step.
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

    /// Builds and registers a `VendorBundle` for Claude Code. The
    /// `accountChangeCallback` runs on the cooperative thread pool when
    /// the active Claude account changes — typically a closure that
    /// forces a poll refresh.
    @discardableResult
    public static func register(
        fileManager: UsagesFileManager = .shared,
        session: URLSession = .shared,
        accountChangeCallback: (@Sendable (AccountEmail) async -> Void)? = nil
    ) -> VendorBundle {
        let logger = Loggers.claude
        let sanitizer = ClaudePayloadSanitizer()
        let proxy = LoggingProxy(logger: logger, sanitizer: sanitizer)
        let connector = ClaudeCodeConnector(logger: logger, session: session)
        let status = ClaudeStatusConnector(logger: logger, session: session)
        let monitor = ClaudeActiveAccountMonitor(
            fileManager: fileManager,
            logger: logger,
            onActiveAccountChanged: accountChangeCallback
        )
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
