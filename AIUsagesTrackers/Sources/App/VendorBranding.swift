import SwiftUI
import AppKit
import AIUsagesTrackersLib

enum VendorBranding {
    struct Brand: Equatable, Sendable {
        let assetName: String
        let displayName: String
        let tintHex: String
    }

    static func brand(for vendor: Vendor) -> Brand? {
        switch vendor {
        case .claude:
            Brand(
                assetName: "claude-mark",
                displayName: "Claude Code",
                tintHex: "DA7756"
            )
        case .codex:
            Brand(
                assetName: "codex-mark",
                displayName: "Codex",
                tintHex: "10A37F"
            )
        default:
            nil
        }
    }

    static func displayName(for vendor: Vendor) -> String {
        brand(for: vendor)?.displayName ?? vendor.rawValue
    }

    static func tint(for vendor: Vendor) -> Color? {
        guard let tintHex = brand(for: vendor)?.tintHex else { return nil }
        return Color(hex: tintHex)
    }

    static func icon(for vendor: Vendor) -> NSImage? {
        guard let assetName = brand(for: vendor)?.assetName else { return nil }
        return loadTemplateImage(named: assetName)
    }

    /// Returns a tinted, non-template copy of the vendor icon at the requested height.
    /// Uses the brand's `tintHex` as fill color and the template PDF as an alpha mask.
    static func tintedNSImage(for vendor: Vendor, height: CGFloat) -> NSImage? {
        guard let template = icon(for: vendor),
              let brand = brand(for: vendor),
              let tintColor = NSColor(hex: brand.tintHex) else { return nil }
        let aspectRatio = template.size.height > 0
            ? template.size.width / template.size.height : 1
        let size = NSSize(width: ceil(height * aspectRatio), height: ceil(height))
        let result = NSImage(size: size)
        result.lockFocus()
        tintColor.setFill()
        NSRect(origin: .zero, size: size).fill()
        template.draw(
            in: NSRect(origin: .zero, size: size),
            from: .zero,
            operation: .destinationIn,
            fraction: 1.0
        )
        result.unlockFocus()
        result.isTemplate = false
        return result
    }

    private static func loadTemplateImage(named assetName: String) -> NSImage? {
        guard let url = Bundle.module.url(
            forResource: assetName,
            withExtension: "pdf",
            subdirectory: "VendorBranding"
        ), let image = NSImage(contentsOf: url) else {
            return nil
        }

        image.isTemplate = true
        return image
    }
}

struct VendorIconView: View {
    let vendor: Vendor
    var size: CGFloat = 14

    var body: some View {
        if let image = VendorBranding.icon(for: vendor),
           let tint = VendorBranding.tint(for: vendor) {
            Image(nsImage: image)
                .renderingMode(.template)
                .resizable()
                .scaledToFit()
                .frame(width: size, height: size)
                .foregroundStyle(tint)
                .accessibilityHidden(true)
        }
    }
}

struct VendorLabelView: View {
    let vendor: Vendor
    var iconSize: CGFloat = 14

    var body: some View {
        HStack(spacing: 6) {
            VendorIconView(vendor: vendor, size: iconSize)
            Text(VendorBranding.displayName(for: vendor))
        }
    }
}

private extension Color {
    init?(hex: String) {
        guard hex.count == 6, let value = Int(hex, radix: 16) else { return nil }

        let red = Double((value >> 16) & 0xFF) / 255.0
        let green = Double((value >> 8) & 0xFF) / 255.0
        let blue = Double(value & 0xFF) / 255.0

        self.init(red: red, green: green, blue: blue)
    }
}

private extension NSColor {
    convenience init?(hex: String) {
        guard hex.count == 6, let value = Int(hex, radix: 16) else { return nil }

        let red = CGFloat((value >> 16) & 0xFF) / 255.0
        let green = CGFloat((value >> 8) & 0xFF) / 255.0
        let blue = CGFloat(value & 0xFF) / 255.0

        self.init(red: red, green: green, blue: blue, alpha: 1.0)
    }
}
