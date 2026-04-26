import Foundation

// MARK: - Remaining time formatting

private let secondsPerMinute = 60
private let secondsPerHour = 3600
private let secondsPerDay = 86400

/// Formats the remaining time until `resetAt` as a compact string (e.g. "2d 5h 13m").
/// Returns `"--"` when `resetAt` cannot be parsed, `"0m"` when the reset date has passed.
public func formatRemainingTime(resetAt: ISODate, now: Date, hideMinutesWhenOverOneDay: Bool = false) -> String {
    guard let resetDate = resetAt.date else { return "--" }
    let totalSeconds = Int(resetDate.timeIntervalSince(now))
    guard totalSeconds > 0 else { return "0m" }

    let days = totalSeconds / secondsPerDay
    let hours = (totalSeconds % secondsPerDay) / secondsPerHour
    let minutes = (totalSeconds % secondsPerHour) / secondsPerMinute

    if hideMinutesWhenOverOneDay, totalSeconds > secondsPerDay {
        let roundedHours = (totalSeconds + secondsPerHour / 2) / secondsPerHour
        let roundedDays = roundedHours / 24
        let remainingHours = roundedHours % 24

        var roundedParts: [String] = []
        if roundedDays > 0 { roundedParts.append("\(roundedDays)d") }
        if remainingHours > 0 { roundedParts.append("\(remainingHours)h") }
        return roundedParts.joined(separator: " ")
    }

    var parts: [String] = []
    if days > 0 { parts.append("\(days)d") }
    if hours > 0 { parts.append("\(hours)h") }
    if minutes > 0 || parts.isEmpty { parts.append("\(minutes)m") }
    return parts.joined(separator: " ")
}

// MARK: - Theoretical fraction

/// Fraction of the time window that has elapsed, clamped to 0...1.
/// Returns 0 when `resetAt` cannot be parsed or `windowDuration` is zero.
public func theoreticalFraction(resetAt: ISODate, windowDuration: DurationMinutes, now: Date) -> Double {
    guard let resetDate = resetAt.date else { return 0 }
    let windowSeconds = Double(windowDuration.rawValue) * 60
    guard windowSeconds > 0 else { return 0 }
    let windowStart = resetDate.addingTimeInterval(-windowSeconds)
    let elapsed = now.timeIntervalSince(windowStart)
    return min(max(elapsed / windowSeconds, 0), 1)
}

// MARK: - Reset date formatting

/// Formats the reset date relative to `now`:
/// - same calendar day → time only ("HH:mm")
/// - next calendar day → "tomorrow HH:mm"
/// - otherwise → "MMM d, HH:mm"
/// Returns "--" when `resetAt` cannot be parsed.
public func formatResetDate(_ resetAt: ISODate, now: Date) -> String {
    guard let resetDate = resetAt.date else { return "--" }
    let calendar = Calendar.current
    let today = calendar.startOfDay(for: now)
    let resetDay = calendar.startOfDay(for: resetDate)
    let timeString = ResetDateFormatting.timeFormatter.string(from: resetDate)
    if resetDay == today {
        return "@ \(timeString)"
    }
    let tomorrow = calendar.date(byAdding: .day, value: 1, to: today)!
    if resetDay == tomorrow {
        return "Tomorrow @ \(timeString)"
    }
    return ResetDateFormatting.dateTimeFormatter.string(from: resetDate)
}

// Singletons are safe: only called from @MainActor SwiftUI views
private enum ResetDateFormatting {
    static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        return f
    }()

    static let dateTimeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "MMM d '@' HH:mm"
        return f
    }()
}

// MARK: - Consumption tier

/// Severity tiers for consumption ratio (actual / theoretical pace).
/// Ordered by severity so `Comparable` yields the worst tier via `max()`.
public enum ConsumptionTier: Int, Comparable, Sendable, CaseIterable {
    case comfortable  // < 0.7
    case onTrack      // [0.7, 0.9)
    case approaching  // [0.9, 1.0)
    case over         // [1.0, 1.2)
    case critical     // [1.2, 1.6)
    case exhausted    // >= 1.6

    public static func < (lhs: ConsumptionTier, rhs: ConsumptionTier) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    private static let comfortableUpperBound = 0.7
    private static let onTrackUpperBound = 0.9
    private static let approachingUpperBound = 1.0
    private static let overUpperBound = 1.2
    private static let criticalUpperBound = 1.6
}

/// Maps a consumption ratio to the appropriate severity tier.
public func consumptionTier(ratio: Double) -> ConsumptionTier {
    switch ratio {
    case ..<0.7:       return .comfortable
    case ..<0.9:       return .onTrack
    case ..<1.0:       return .approaching
    case ..<1.2:       return .over
    case ..<1.6:       return .critical
    default:           return .exhausted
    }
}

/// Computes the consumption ratio: how fast actual usage is relative to theoretical pace.
/// Returns `nil` when `theoreticalFraction` is zero or negative (window not started).
public func consumptionRatio(actualPercent: UsagePercent, theoreticalFraction: Double) -> Double? {
    guard theoreticalFraction > 0 else { return nil }
    return Double(actualPercent.rawValue) / (theoreticalFraction * 100.0)
}

// MARK: - Entry sorting

extension Array where Element == VendorUsageEntry {
    /// Sorted by vendor name, then active-first within each vendor, then account name.
    public func sortedForDisplay() -> [VendorUsageEntry] {
        sorted { lhs, rhs in
            if lhs.vendor.rawValue != rhs.vendor.rawValue {
                return lhs.vendor.rawValue < rhs.vendor.rawValue
            }
            if lhs.isActive != rhs.isActive {
                return lhs.isActive
            }
            return lhs.account.rawValue < rhs.account.rawValue
        }
    }

    /// Returns entries that are not in the ignored set.
    public func excluding(ignoredAccounts: [IgnoredAccount]) -> [VendorUsageEntry] {
        let ignoredSet = Set(ignoredAccounts)
        return filter { !ignoredSet.contains(IgnoredAccount(vendor: $0.vendor, account: $0.account)) }
    }

    /// Set of vendors that appear more than once in the array.
    public func vendorsWithMultipleAccounts() -> Set<Vendor> {
        var counts: [Vendor: Int] = [:]
        for entry in self {
            counts[entry.vendor, default: 0] += 1
        }
        return Set(counts.filter { $0.value > 1 }.keys)
    }
}
