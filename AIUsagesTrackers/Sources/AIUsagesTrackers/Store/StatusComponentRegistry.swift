import Foundation

/// Reads / refreshes the cached list of status-page components for a given
/// (platform, host, group root) triple, and exposes the resolved
/// "subscribed component IDs" set that status connectors filter against.
///
/// The registry stays empty on a fresh install with no successful refresh —
/// in that state `subscribedComponentIDs()` returns nil, which connectors
/// treat as "no filter known yet, drop everything". This is the explicit
/// design choice from the roadmap: the initial release ships with an empty
/// seed so the first user-visible refresh exercises the discovery path
/// end-to-end and parser regressions surface immediately instead of being
/// masked by a silent fallback.
public actor StatusComponentRegistry {
    public let platform: StatusPlatform
    public let host: String
    public let groupRootID: StatusComponentID

    private let discovery: any IncidentIOComponentsDiscovery
    private let cache: StatusComponentsFileManager
    private let logger: FileLogger
    private let cacheTTL: TimeInterval
    private let clock: @Sendable () -> Date

    public init(
        platform: StatusPlatform,
        host: String,
        groupRootID: StatusComponentID,
        discovery: any IncidentIOComponentsDiscovery,
        cache: StatusComponentsFileManager = .shared,
        logger: FileLogger = Loggers.app,
        cacheTTL: TimeInterval = 24 * 60 * 60,
        clock: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.platform = platform
        self.host = host
        self.groupRootID = groupRootID
        self.discovery = discovery
        self.cache = cache
        self.logger = logger
        self.cacheTTL = cacheTTL
        self.clock = clock
    }

    /// Returns the cached entry, or nil if discovery has never succeeded.
    public func cachedEntry() async -> StatusComponentsCacheEntry? {
        let cached = await cache.read()
        return cached.entry(platform: platform, host: host, groupRootID: groupRootID)
    }

    /// Performs the discovery + writes the cache + returns the new entry.
    /// Throws on network / parse / no-match errors so the UI can surface
    /// them.
    @discardableResult
    public func refresh() async throws -> StatusComponentsCacheEntry {
        let components = try await discovery.discover(host: host, groupRootID: groupRootID)
        let entry = StatusComponentsCacheEntry(
            platform: platform,
            host: host,
            groupRootID: groupRootID,
            lastRefreshedAt: ISODate(date: clock()),
            components: components
        )
        await cache.upsert(entry)
        return entry
    }

    /// Refresh if the cache is missing or older than `cacheTTL`. Errors are
    /// logged but swallowed — this entry point is used on app start where
    /// surfacing failures noisily would be intrusive (the Settings tab has
    /// its own Refresh-now button that does throw).
    public func refreshIfStale() async {
        let existing = await cachedEntry()
        if let existing,
           let lastRefreshed = existing.lastRefreshedAt.date,
           clock().timeIntervalSince(lastRefreshed) < cacheTTL {
            logger.log(
                .debug,
                "Status components cache for \(host) is fresh (last refresh \(existing.lastRefreshedAt.rawValue))"
            )
            return
        }
        do {
            let entry = try await refresh()
            logger.log(
                .info,
                "Refreshed \(entry.components.count) status component(s) for \(host)"
            )
        } catch {
            logger.log(
                .warning,
                "Status components refresh failed for \(host): \(error) — keeping last successful cache"
            )
        }
    }
}
