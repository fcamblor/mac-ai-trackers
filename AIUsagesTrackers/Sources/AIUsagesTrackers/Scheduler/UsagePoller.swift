import Foundation

public actor UsagePoller {
    public let connectors: [any UsageConnector]
    public let statusConnectors: [any StatusConnector]
    public let fileManager: UsagesFileManager
    private let logger: FileLogger
    private let refreshState: RefreshState?
    // Set once at init and never mutated; nonisolated to allow cross-actor reads
    // without sending through actor isolation (the @MainActor conformance of
    // AppPreferences makes it Sendable).
    private nonisolated let preferences: (any AppPreferences)?
    /// Fallback interval used when no preferences store is injected (e.g. tests).
    private let fixedInterval: Duration?

    private var pollingTask: Task<Void, Never>?

    /// Production initializer — reads refresh interval from preferences on each tick
    /// so changes take effect without restarting the poller.
    public init(
        connectors: [any UsageConnector],
        statusConnectors: [any StatusConnector] = [],
        fileManager: UsagesFileManager = UsagesFileManager.shared,
        logger: FileLogger = Loggers.app,
        refreshState: RefreshState? = nil,
        preferences: any AppPreferences
    ) {
        self.connectors = connectors
        self.statusConnectors = statusConnectors
        self.fileManager = fileManager
        self.logger = logger
        self.refreshState = refreshState
        self.preferences = preferences
        self.fixedInterval = nil
    }

    /// Test/legacy initializer — uses a fixed interval instead of preferences.
    public init(
        connectors: [any UsageConnector],
        statusConnectors: [any StatusConnector] = [],
        interval: Duration = .seconds(180),
        fileManager: UsagesFileManager = UsagesFileManager.shared,
        logger: FileLogger = Loggers.app,
        refreshState: RefreshState? = nil
    ) {
        self.connectors = connectors
        self.statusConnectors = statusConnectors
        self.fileManager = fileManager
        self.logger = logger
        self.refreshState = refreshState
        self.preferences = nil
        self.fixedInterval = interval
    }

    /// Resolves the current polling interval — reads from preferences (main actor hop)
    /// or falls back to the fixed interval.
    private func currentInterval() async -> Duration {
        if let preferences {
            return await MainActor.run { preferences.refreshInterval.duration }
        }
        return fixedInterval ?? .seconds(180)
    }

    public func start() {
        guard pollingTask == nil else {
            logger.log(.warning, "Poller already running")
            return
        }
        pollingTask = Task {
            while !Task.isCancelled {
                await self.pollOnce()
                // Re-read interval each tick so settings changes take effect immediately.
                let sleepDuration = await self.currentInterval()
                try? await Task.sleep(for: sleepDuration)
                guard !Task.isCancelled else { break }
            }
        }
    }

    public func stop() {
        pollingTask?.cancel()
        pollingTask = nil
        logger.log(.info, "Poller stopped")
    }

    public func pollOnce(now: Date = Date(), force: Bool = false) async {
        logger.log(.debug, "Poll tick — fetching from \(connectors.count) connector(s)\(force ? " (forced)" : "")")

        let existingFile = await fileManager.read()
        let currentInterval = await self.currentInterval()
        let intervalSeconds = Double(currentInterval.components.seconds)
        var skippedCount = 0
        let log = self.logger

        let refreshState = self.refreshState
        let usagesByVendor = Dictionary(grouping: existingFile.usages, by: \.vendor)
        let entries: [VendorUsageEntry] = await withTaskGroup(of: [VendorUsageEntry].self) { group in
            for connector in connectors {
                let cachedForVendor = usagesByVendor[connector.vendor] ?? []
                var cacheByAccount: [AccountEmail: VendorUsageEntry] = [:]
                for entry in cachedForVendor {
                    cacheByAccount[entry.account] = entry
                }
                let knownAccounts = connector.knownAccounts()
                let accountsToCheck: [AccountEmail]
                if knownAccounts.isEmpty {
                    accountsToCheck = connector.resolveActiveAccount().map { [$0] } ?? []
                } else {
                    accountsToCheck = Array(Set(knownAccounts + cachedForVendor.map(\.account)))
                }
                let shouldSkip: Bool
                if force || accountsToCheck.isEmpty {
                    shouldSkip = false
                } else {
                    shouldSkip = accountsToCheck.allSatisfy { account in
                        guard let acquiredDate = cacheByAccount[account]?.lastAcquiredOn?.date else {
                            return false
                        }
                        return now.timeIntervalSince(acquiredDate) < intervalSeconds
                    }
                }
                if shouldSkip {
                    let age = accountsToCheck.compactMap { account in
                        cacheByAccount[account]?.lastAcquiredOn?.date
                    }.map { Int(now.timeIntervalSince($0)) }.max()
                    logger.log(
                        .debug,
                        "Skipping \(connector.vendor) — all \(accountsToCheck.count) account(s) fresh (max age \(age ?? -1)s < \(Int(intervalSeconds))s)"
                    )
                    skippedCount += 1
                    continue
                }
                let refreshKey = connector.resolveActiveAccount().map {
                    AccountKey(vendor: connector.vendor, account: $0)
                }
                if let refreshKey {
                    await refreshState?.begin(refreshKey)
                }
                group.addTask {
                    let result: [VendorUsageEntry]
                    do {
                        result = try await connector.fetchUsages()
                    } catch {
                        log.log(.error, "Connector \(connector.vendor) threw: \(error)")
                        result = []
                    }
                    if let refreshKey {
                        await refreshState?.end(refreshKey)
                    }
                    return result
                }
            }
            var all: [VendorUsageEntry] = []
            for await batch in group {
                all.append(contentsOf: batch)
            }
            return all
        }

        // Status connectors run on every tick (no freshness cache) and in parallel with usages.
        // Vendors whose fetch fails are omitted from the map so their prior outages survive.
        let statusLog = self.logger
        let outagesByVendor: [Vendor: [Outage]] = await withTaskGroup(
            of: (Vendor, Result<[Outage], Error>).self
        ) { group in
            for statusConnector in statusConnectors {
                group.addTask {
                    do {
                        let outages = try await statusConnector.fetchOutages()
                        return (statusConnector.vendor, .success(outages))
                    } catch {
                        return (statusConnector.vendor, .failure(error))
                    }
                }
            }
            var byVendor: [Vendor: [Outage]] = [:]
            for await (vendor, result) in group {
                switch result {
                case .success(let outages):
                    byVendor[vendor] = outages
                case .failure(let error):
                    statusLog.log(.warning, "Status fetch failed for \(vendor): \(error) — preserving existing outages")
                }
            }
            return byVendor
        }

        guard !entries.isEmpty || !outagesByVendor.isEmpty else {
            if skippedCount == connectors.count && statusConnectors.isEmpty {
                logger.log(.debug, "All \(connectors.count) connector(s) up-to-date — skipping file write")
            } else {
                logger.log(.warning, "No entries returned from any connector")
            }
            return
        }

        await fileManager.update(with: entries, outagesByVendor: outagesByVendor)
        logger.log(.info, "Merged \(entries.count) usage entry/entries and \(outagesByVendor.count) outage vendor(s) into usages file")
    }
}
