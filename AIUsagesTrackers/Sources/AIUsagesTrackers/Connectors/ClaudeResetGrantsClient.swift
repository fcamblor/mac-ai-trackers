import Foundation

struct ClaudeResetGrantSnapshot: Sendable, Equatable {
    let resetCredits: ResetCredits?
    let responseTier: String?
}

/// Shares the slower grant lookup between Claude Code and Desktop when both
/// sources resolve to the same account.
private actor ClaudeResetGrantsCoordinator {
    static let shared = ClaudeResetGrantsCoordinator()
    static let checkInterval: TimeInterval = 60 * 60

    struct Check: Sendable {
        let shouldFetch: Bool
        let cachedSnapshot: ClaudeResetGrantSnapshot?
    }

    private struct State {
        var checkedAt: Date
        var snapshot: ClaudeResetGrantSnapshot?
    }

    private var stateByAccount: [AccountEmail: State] = [:]

    func reserveCheck(for account: AccountEmail, now: Date) -> Check {
        if var state = stateByAccount[account] {
            guard now.timeIntervalSince(state.checkedAt) >= Self.checkInterval else {
                return Check(shouldFetch: false, cachedSnapshot: state.snapshot)
            }
            state.checkedAt = now
            stateByAccount[account] = state
            return Check(shouldFetch: true, cachedSnapshot: state.snapshot)
        }

        stateByAccount[account] = State(checkedAt: now, snapshot: nil)
        return Check(shouldFetch: true, cachedSnapshot: nil)
    }

    func store(_ snapshot: ClaudeResetGrantSnapshot, for account: AccountEmail) {
        guard var state = stateByAccount[account] else { return }
        state.snapshot = snapshot
        stateByAccount[account] = state
    }
}

struct ClaudeResetGrantsClient: Sendable {
    let session: URLSession
    let logger: FileLogger

    func snapshotIfDue(account: AccountEmail, token: String, now: Date) async -> ClaudeResetGrantSnapshot? {
        let coordinator = ClaudeResetGrantsCoordinator.shared
        let check = await coordinator.reserveCheck(for: account, now: now)
        guard check.shouldFetch else { return check.cachedSnapshot }

        var request = URLRequest(url: ClaudeUsageResponseParser.resetGrantsURL)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        request.timeoutInterval = ClaudeUsageResponseParser.requestTimeoutSeconds

        do {
            let (data, response) = try await session.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? -1
            guard status == 200 else {
                logger.log(.debug, "Claude reset-grant request for account=\(account) returned HTTP \(status)")
                return check.cachedSnapshot
            }

            let snapshot = try ClaudeUsageResponseParser().parseResetGrantResponse(data)
            await coordinator.store(snapshot, for: account)
            return snapshot
        } catch {
            logger.log(.debug, "Claude reset-grant request for account=\(account) failed: \(error)")
            return check.cachedSnapshot
        }
    }
}
