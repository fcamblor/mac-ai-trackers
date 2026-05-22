import SwiftUI

/// Lightweight block-level Markdown renderer for GitHub release notes.
///
/// SwiftUI's `Text(_:)` only handles inline Markdown (bold, italic, code,
/// links) and collapses line breaks. Release notes typically mix headings,
/// bullet lists and paragraphs, so we parse blocks line-by-line and delegate
/// inline formatting to `AttributedString(markdown:)`.
struct ReleaseNotesMarkdownView: View {
    let markdown: String

    private var blocks: [MarkdownBlock] { MarkdownBlockParser.parse(markdown) }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                blockView(block)
            }
        }
    }

    @ViewBuilder
    private func blockView(_ block: MarkdownBlock) -> some View {
        switch block {
        case .heading(let level, let text):
            Text(inline(text))
                .font(.system(size: headingSize(level), weight: .semibold))
                .fixedSize(horizontal: false, vertical: true)
        case .paragraph(let text):
            Text(inline(text))
                .font(.system(size: 11))
                .fixedSize(horizontal: false, vertical: true)
        case .bullet(let items):
            VStack(alignment: .leading, spacing: 3) {
                ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                    HStack(alignment: .top, spacing: 6) {
                        Text("•")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                        Text(inline(item))
                            .font(.system(size: 11))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        case .code(let body):
            Text(body)
                .font(.system(size: 10, design: .monospaced))
                .padding(6)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.secondary.opacity(0.10), in: RoundedRectangle(cornerRadius: 4))
                .textSelection(.enabled)
        }
    }

    private func inline(_ text: String) -> AttributedString {
        var options = AttributedString.MarkdownParsingOptions()
        options.interpretedSyntax = .inlineOnlyPreservingWhitespace
        if let attributed = try? AttributedString(markdown: text, options: options) {
            return attributed
        }
        return AttributedString(text)
    }

    private func headingSize(_ level: Int) -> CGFloat {
        switch level {
        case 1: return 14
        case 2: return 13
        default: return 12
        }
    }
}

enum MarkdownBlock: Equatable {
    case heading(level: Int, text: String)
    case paragraph(String)
    case bullet([String])
    case code(String)
}

enum MarkdownBlockParser {
    static func parse(_ source: String) -> [MarkdownBlock] {
        var blocks: [MarkdownBlock] = []
        var paragraphBuffer: [String] = []
        var bulletBuffer: [String] = []
        var codeBuffer: [String] = []
        var inCodeFence = false

        func flushParagraph() {
            guard !paragraphBuffer.isEmpty else { return }
            blocks.append(.paragraph(paragraphBuffer.joined(separator: " ")))
            paragraphBuffer.removeAll()
        }
        func flushBullets() {
            guard !bulletBuffer.isEmpty else { return }
            blocks.append(.bullet(bulletBuffer))
            bulletBuffer.removeAll()
        }

        for rawLine in source.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(rawLine)

            if line.trimmingCharacters(in: .whitespaces).hasPrefix("```") {
                if inCodeFence {
                    blocks.append(.code(codeBuffer.joined(separator: "\n")))
                    codeBuffer.removeAll()
                    inCodeFence = false
                } else {
                    flushParagraph()
                    flushBullets()
                    inCodeFence = true
                }
                continue
            }
            if inCodeFence {
                codeBuffer.append(line)
                continue
            }

            let trimmed = line.trimmingCharacters(in: .whitespaces)

            if trimmed.isEmpty {
                flushParagraph()
                flushBullets()
                continue
            }

            if let heading = parseHeading(trimmed) {
                flushParagraph()
                flushBullets()
                blocks.append(heading)
                continue
            }

            if let bullet = parseBullet(trimmed) {
                flushParagraph()
                bulletBuffer.append(bullet)
                continue
            }

            flushBullets()
            paragraphBuffer.append(trimmed)
        }

        if inCodeFence, !codeBuffer.isEmpty {
            blocks.append(.code(codeBuffer.joined(separator: "\n")))
        }
        flushParagraph()
        flushBullets()
        return blocks
    }

    private static func parseHeading(_ line: String) -> MarkdownBlock? {
        var level = 0
        var index = line.startIndex
        while index < line.endIndex, line[index] == "#", level < 6 {
            level += 1
            index = line.index(after: index)
        }
        guard level > 0, index < line.endIndex, line[index] == " " else { return nil }
        let text = String(line[line.index(after: index)...]).trimmingCharacters(in: .whitespaces)
        return .heading(level: level, text: text)
    }

    private static func parseBullet(_ line: String) -> String? {
        for marker in ["- ", "* ", "+ "] where line.hasPrefix(marker) {
            return String(line.dropFirst(marker.count))
        }
        return nil
    }
}
