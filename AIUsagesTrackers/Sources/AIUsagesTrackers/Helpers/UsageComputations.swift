import Foundation

// MARK: - Remaining time formatting

private let secondsPerMinute = 60
private let secondsPerHour = 3600
private let secondsPerDay = 86400

/// Formats the remaining time until `resetAt` as a compact string (e.g. "2d 5h 13m").
/// Returns `"--"` when `resetAt` cannot be parsed, `"0m"` when the reset date has passed.
public func formatRemainingTime(resetAt: ISODate, now: Date) -> String {
    guard let resetDate = resetAt.date else { return "--" }
    let totalSeconds = Int(resetDate.timeIntervalSince(now))
    guard totalSeconds > 0 else { return "0m" }

    let days = totalSeconds / secondsPerDay
    let hours = (totalSeconds % secondsPerDay) / secondsPerHour
    let minutes = (totalSeconds % secondsPerHour) / secondsPerMinute

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

/// Formats the reset date as "MMM d, HH:mm". Returns "--" when `resetAt` cannot be parsed.
public func formatResetDate(_ resetAt: ISODate) -> String {
    guard let resetDate = resetAt.date else { return "--" }
    return ResetDateFormatting.formatter.string(from: resetDate)
}

// Singleton is safe: only called from @MainActor SwiftUI views
private enum ResetDateFormatting {
    static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "MMM d, HH:mm"
        return f
    }()
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

    /// Set of vendors that appear more than once in the array.
    public func vendorsWithMultipleAccounts() -> Set<Vendor> {
        var counts: [Vendor: Int] = [:]
        for entry in self {
            counts[entry.vendor, default: 0] += 1
        }
        return Set(counts.filter { $0.value > 1 }.keys)
    }
}
