import SwiftUI
import AppKit
import AIUsagesTrackersLib

/// Modal sheet that renders the release notes Markdown body in a comfortable,
/// scrollable area. The popover-anchored banner only exposes a button that
/// opens this sheet — inlining the notes was breaking the layout when the
/// release notes were long enough to push action buttons above the menu bar.
struct ReleaseNotesSheet: View {
    let version: AppVersion
    let publishedAt: Date?
    let markdown: String
    let releaseURL: URL
    let onDismiss: () -> Void

    private static let sheetWidth: CGFloat = 520
    private static let sheetMaxHeight: CGFloat = 560

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            Divider()
            ScrollView(.vertical, showsIndicators: true) {
                ReleaseNotesMarkdownView(markdown: markdown)
                    .padding(16)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: Self.sheetMaxHeight)
            .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(Color.secondary.opacity(0.20), lineWidth: 1)
            )
            Divider()
            footer
        }
        .padding(16)
        .frame(width: Self.sheetWidth)
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            Image(systemName: "sparkles")
                .foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 2) {
                Text("Release notes")
                    .font(.system(size: 13, weight: .semibold))
                HStack(spacing: 6) {
                    Text("Version \(version.rawValue)")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                    if let publishedAt {
                        Text("·")
                            .foregroundStyle(.tertiary)
                        Text(publishedAt, style: .date)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                }
            }
            Spacer()
            Button {
                onDismiss()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.borderless)
            .keyboardShortcut(.cancelAction)
        }
    }

    private var footer: some View {
        HStack {
            Button {
                NSWorkspace.shared.open(releaseURL)
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "arrow.up.right.square")
                    Text("View on GitHub")
                }
            }
            .buttonStyle(.borderless)
            Spacer()
            Button("Close") { onDismiss() }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
        }
    }
}
