import Foundation

/// Which popover rows the user chose to hide, per assistant family
/// (`Vendor.accountFamily`). Only the popover reads it: menu bar chips and
/// charts keep resolving hidden metrics, so hiding never breaks a config.
///
/// Rows are keyed by metric name, plus the `PopoverStatusRow` names for
/// account-status rows. The block banner is deliberately not hideable — it is
/// the one row that answers "can I use it right now?".
public struct PopoverMetricVisibility: Codable, Equatable, Sendable {
    /// family → hidden row names. Families with nothing hidden are absent.
    public private(set) var hiddenByFamily: [String: Set<String>]

    public init(hiddenByFamily: [String: Set<String>] = [:]) {
        self.hiddenByFamily = hiddenByFamily.filter { !$0.value.isEmpty }
    }

    public func isHidden(_ rowName: String, family: String) -> Bool {
        hiddenByFamily[family]?.contains(rowName) ?? false
    }

    public func isHidden(_ rowName: String, vendor: Vendor) -> Bool {
        isHidden(rowName, family: vendor.accountFamily)
    }

    public mutating func setHidden(_ hidden: Bool, rowName: String, family: String) {
        var rows = hiddenByFamily[family] ?? []
        if hidden {
            rows.insert(rowName)
        } else {
            rows.remove(rowName)
        }
        hiddenByFamily[family] = rows.isEmpty ? nil : rows
    }

    // Sets encode in arbitrary order; sorting keeps the stored JSON stable
    // so identical preferences produce identical bytes.
    private struct Stored: Codable {
        let hiddenByFamily: [String: [String]]
    }

    public init(from decoder: Decoder) throws {
        let stored = try Stored(from: decoder)
        self.init(hiddenByFamily: stored.hiddenByFamily.mapValues(Set.init))
    }

    public func encode(to encoder: Encoder) throws {
        try Stored(hiddenByFamily: hiddenByFamily.mapValues { $0.sorted() }).encode(to: encoder)
    }
}

/// Names of the account-status rows that can be hidden like metrics.
public enum PopoverStatusRow {
    public static let messagesLeft = "Messages left"
    public static let unavailableModels = "Unavailable models"
}

/// A family's hideable rows, in first-seen display order.
public struct PopoverRowCatalogEntry: Equatable, Sendable {
    public let family: String
    /// The vendor whose branding represents the family in the settings.
    public let representativeVendor: Vendor
    public let rowNames: [String]

    public var groups: [PopoverRowGroup] { PopoverRowGroup.grouping(rowNames) }
}

/// Rows sharing a `"<prefix> · <name>"` name (Claude's weekly shares) are
/// presented together so the whole family can be toggled at once.
public struct PopoverRowGroup: Equatable, Sendable {
    public struct Row: Equatable, Sendable {
        /// Full metric name — the key stored in `PopoverMetricVisibility`.
        public let name: String
        /// Name shown inside the group (prefix stripped).
        public let label: String
    }

    /// nil for the leading group of standalone rows.
    public let title: String?
    public let rows: [Row]

    static let separator = " · "

    /// Standalone rows first (display order), then one group per prefix that
    /// at least two rows share. A prefix used once stays a standalone row.
    public static func grouping(_ rowNames: [String]) -> [PopoverRowGroup] {
        var prefixCounts: [String: Int] = [:]
        for name in rowNames {
            if let range = name.range(of: separator) {
                prefixCounts[String(name[..<range.lowerBound]), default: 0] += 1
            }
        }
        var standalone: [Row] = []
        var prefixOrder: [String] = []
        var rowsByPrefix: [String: [Row]] = [:]
        for name in rowNames {
            if let range = name.range(of: separator) {
                let prefix = String(name[..<range.lowerBound])
                if prefixCounts[prefix, default: 0] > 1 {
                    if rowsByPrefix[prefix] == nil { prefixOrder.append(prefix) }
                    rowsByPrefix[prefix, default: []].append(Row(name: name, label: String(name[range.upperBound...])))
                    continue
                }
            }
            standalone.append(Row(name: name, label: name))
        }
        var groups: [PopoverRowGroup] = []
        if !standalone.isEmpty { groups.append(PopoverRowGroup(title: nil, rows: standalone)) }
        for prefix in prefixOrder {
            groups.append(PopoverRowGroup(title: prefix, rows: rowsByPrefix[prefix] ?? []))
        }
        return groups
    }
}

public enum PopoverRowCatalog {
    /// Rows the user can toggle, built from what the current entries actually
    /// display, plus rows already hidden (so a hidden row whose metric
    /// disappeared can still be un-hidden). Families keep first-seen order.
    public static func build(
        entries: [VendorUsageEntry],
        visibility: PopoverMetricVisibility
    ) -> [PopoverRowCatalogEntry] {
        var familyOrder: [String] = []
        var vendorByFamily: [String: Vendor] = [:]
        var rowsByFamily: [String: [String]] = [:]

        func add(_ row: String, family: String) {
            if rowsByFamily[family]?.contains(row) == true { return }
            rowsByFamily[family, default: []].append(row)
        }

        for entry in entries {
            let family = entry.vendor.accountFamily
            if vendorByFamily[family] == nil {
                familyOrder.append(family)
                vendorByFamily[family] = entry.vendor.familyCanonicalVendor
            }
            for metric in entry.metrics {
                switch metric {
                case .timeWindow(let name, _, _, _), .payAsYouGo(let name, _, _):
                    add(name, family: family)
                case .unknown:
                    break
                }
            }
            if entry.accountStatus?.credits != nil {
                add(PopoverStatusRow.messagesLeft, family: family)
            }
            if entry.accountStatus?.unavailableModels.isEmpty == false {
                add(PopoverStatusRow.unavailableModels, family: family)
            }
        }

        for (family, hidden) in visibility.hiddenByFamily.sorted(by: { $0.key < $1.key }) {
            if vendorByFamily[family] == nil {
                familyOrder.append(family)
                vendorByFamily[family] = Vendor(rawValue: family)
            }
            for row in hidden.sorted() {
                add(row, family: family)
            }
        }

        return familyOrder.compactMap { family in
            guard let vendor = vendorByFamily[family], let rows = rowsByFamily[family], !rows.isEmpty else {
                return nil
            }
            return PopoverRowCatalogEntry(family: family, representativeVendor: vendor, rowNames: rows)
        }
    }
}
