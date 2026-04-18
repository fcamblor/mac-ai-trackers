import Foundation

public actor UsagePoller {
    public let connectors: [any UsageConnector]
    public let interval: Duration
    public let fileManager: UsagesFileManager
    private let logger: FileLogger
    private let refreshState: RefreshState?

    private var pollingTask: Task<Void, Never>?

    public init(
        connectors: [any UsageConnector],
        interval: Duration = .seconds(180),
        fileManager: UsagesFileManager = UsagesFileManager.shared,
        logger: FileLogger = Loggers.app,
        refreshState: RefreshState? = nil
    ) {
        self.connectors = connectors
        self.interval = interval
        self.fileManager = fileManager
        self.logger = logger
        self.refreshState = refreshState
    }

    public func start() {
        guard pollingTask == nil else {
            logger.log(.warning, "Poller already running")
            return
        }
        logger.log(.info, "Starting poller with interval \(interval)")
        pollingTask = Task {
            while !Task.isCancelled {
                await self.pollOnce()
                // Sleep-based cadence: effective period = poll duration + interval.
                // This is intentional — avoids overlapping polls at the cost of slight drift.
                try? await Task.sleep(for: self.interval)
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
        let intervalSeconds = Double(interval.components.seconds)
        var skippedCount = 0
        let log = self.logger

        let refreshState = self.refreshState
        let entries: [VendorUsageEntry] = await withTaskGroup(of: [VendorUsageEntry].self) { group in
            for connector in connectors {
                let account = connector.resolveActiveAccount()
                if !force,
                   let account,
                   let cached = existingFile.usages.first(where: { $0.vendor == connector.vendor && $0.account == account }),
                   let acquiredDate = cached.lastAcquiredOn?.date,
                   now.timeIntervalSince(acquiredDate) < intervalSeconds {
                    let age = Int(now.timeIntervalSince(acquiredDate))
                    logger.log(.debug, "Skipping \(connector.vendor)/\(account) — fresh (age \(age)s < \(Int(intervalSeconds))s)")
                    skippedCount += 1
                    continue
                }
                let refreshKey = account.map { AccountKey(vendor: connector.vendor, account: $0) }
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

        guard !entries.isEmpty else {
            if skippedCount == connectors.count {
                logger.log(.debug, "All \(connectors.count) connector(s) up-to-date — skipping file write")
            } else {
                logger.log(.warning, "No entries returned from any connector")
            }
            return
        }

        await fileManager.update(with: entries)
        logger.log(.info, "Merged \(entries.count) entry/entries into usages file")
    }
}
