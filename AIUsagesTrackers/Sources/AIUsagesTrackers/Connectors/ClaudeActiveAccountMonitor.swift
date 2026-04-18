import Foundation

public actor ClaudeActiveAccountMonitor {
    // 15 s: short enough to react to account switches without hammering the disk.
    // Public so it can be referenced as a default argument value in callers' code.
    public static let defaultInterval: Duration = .seconds(15)

    private let claudeConfigPath: String
    private let fileManager: UsagesFileManager
    private let logger: FileLogger
    private let interval: Duration
    private let onActiveAccountChanged: (@Sendable (AccountEmail) async -> Void)?

    private var monitorTask: Task<Void, Never>?
    private var lastObservedActiveAccount: AccountEmail?

    private static let monitoredVendor: Vendor = .claude

    public init(
        claudeConfigPath: String? = nil,
        fileManager: UsagesFileManager,
        logger: FileLogger = Loggers.claude,
        interval: Duration = ClaudeActiveAccountMonitor.defaultInterval,
        onActiveAccountChanged: (@Sendable (AccountEmail) async -> Void)? = nil
    ) {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        self.claudeConfigPath = claudeConfigPath ?? "\(home)/.claude.json"
        self.fileManager = fileManager
        self.logger = logger
        self.interval = interval
        self.onActiveAccountChanged = onActiveAccountChanged
    }

    public func start() {
        guard monitorTask == nil else {
            logger.log(.warning, "Active-account monitor already running")
            return
        }
        logger.log(.info, "Starting active-account monitor with interval \(interval)")
        monitorTask = Task {
            while !Task.isCancelled {
                await self.checkOnce()
                try? await Task.sleep(for: self.interval)
                guard !Task.isCancelled else { break }
            }
        }
    }

    public func stop() {
        monitorTask?.cancel()
        monitorTask = nil
        logger.log(.info, "Active-account monitor stopped")
    }

    public func checkOnce() async {
        guard let active = readActiveAccount() else {
            // `/login` rewrites `.claude.json` through a transient state where `oauthAccount`
            // is absent (user briefly logged out between accounts). Treating that as "no active
            // account" would blank the menu bar label for up to one poll interval.
            // We only trust positive signals — preserve the previous isActive state otherwise.
            logger.log(.debug, "Active account unresolved — keeping previous isActive state")
            return
        }
        await fileManager.updateIsActive(vendor: Self.monitoredVendor, activeAccount: active)
        logger.log(.debug, "isActive updated: activeAccount=\(active.rawValue)")

        let previous = lastObservedActiveAccount
        lastObservedActiveAccount = active
        // Skip the callback on the first resolution (startup) — only fire on genuine switches,
        // so we don't force a redundant poll the first time the monitor sees an account.
        if let previous, previous != active {
            await onActiveAccountChanged?(active)
        }
    }

    private func readActiveAccount() -> AccountEmail? {
        guard let data = FileManager.default.contents(atPath: claudeConfigPath) else {
            logger.log(.warning, "Cannot read \(claudeConfigPath)")
            return nil
        }
        do {
            let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            let oauth = json?["oauthAccount"] as? [String: Any]
            return (oauth?["emailAddress"] as? String).map(AccountEmail.init(rawValue:))
        } catch {
            logger.log(.error, "Failed to parse \(claudeConfigPath): \(error)")
            return nil
        }
    }
}
