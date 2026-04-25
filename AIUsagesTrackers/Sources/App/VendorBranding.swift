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
