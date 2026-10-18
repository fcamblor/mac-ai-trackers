import Foundation

/// Width preset of the menu bar popover. Closed set: an unknown stored value
/// (written by a newer build) falls back to `.standard` at the preference layer.
public enum PopoverWidth: String, CaseIterable, Sendable {
    case standard
    case large

    public static let `default`: PopoverWidth = .standard

    /// Width the popover cards were designed for.
    public static let standardPoints: Double = 320
    /// Large gives long metric names and side-by-side figures room to breathe.
    public static let largeMultiplier: Double = 1.5

    public var points: Double {
        switch self {
        case .standard: Self.standardPoints
        case .large: Self.standardPoints * Self.largeMultiplier
        }
    }
}
