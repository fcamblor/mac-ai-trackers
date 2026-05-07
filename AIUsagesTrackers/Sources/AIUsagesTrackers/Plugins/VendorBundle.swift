import Foundation

/// Everything `AppDelegate` needs to wire a vendor into the app: identity,
/// branding, the four connectors (usage / status / monitor / credentials
/// are owned by the connectors themselves), the file logger, the
/// sanitization-enforcing logging proxy, and the documentation pointer.
///
/// `status` and `activeAccountMonitor` are optional because not every
/// vendor exposes either. The framework treats `nil` as "feature disabled
/// for this vendor", not as "partial implementation".
public struct VendorBundle: Sendable {
    public let vendor: Vendor
    public let branding: VendorBranding
    public let usage: any UsageConnector
    public let status: (any StatusConnector)?
    public let activeAccountMonitor: (any ActiveAccountMonitoring)?
    public let logger: FileLogger
    public let loggingProxy: LoggingProxy
    public let sanitizer: any PayloadSanitizing
    public let documentation: VendorDocumentation

    public init(
        vendor: Vendor,
        branding: VendorBranding,
        usage: any UsageConnector,
        status: (any StatusConnector)? = nil,
        activeAccountMonitor: (any ActiveAccountMonitoring)? = nil,
        logger: FileLogger,
        loggingProxy: LoggingProxy,
        sanitizer: any PayloadSanitizing,
        documentation: VendorDocumentation
    ) {
        self.vendor = vendor
        self.branding = branding
        self.usage = usage
        self.status = status
        self.activeAccountMonitor = activeAccountMonitor
        self.logger = logger
        self.loggingProxy = loggingProxy
        self.sanitizer = sanitizer
        self.documentation = documentation
    }
}
