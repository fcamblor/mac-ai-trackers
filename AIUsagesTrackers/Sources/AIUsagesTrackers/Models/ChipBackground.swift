import Foundation

/// User-selectable colour scheme for the menu bar chip pill. Three curated
/// options is the deliberate ceiling: more variants would force callers to
/// hand-tune every tier colour for every background, breaking the contrast
/// guarantees that make the colored-text feature legible.
public enum ChipBackground: String, Codable, Equatable, Hashable, Sendable, CaseIterable {
    /// Off-white pill on any wallpaper. Default — matches the original mockup.
    case paper
    /// Slate-grey pill. Reads as a dark "card" against light wallpapers and
    /// blends naturally into dark wallpapers.
    case slate
    /// Pill colour follows the menu bar appearance: paper when the menu bar
    /// is in its light state, slate when it is dark. The renderer reads the
    /// status button's `effectiveAppearance` to decide.
    case system

    public static let `default`: ChipBackground = .paper
}
