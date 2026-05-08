import Foundation

/// Pure builder for the tester sign-off comment Markdown described in
/// `docs/ASSISTANT-ONBOARDING.md` §3.1.5. Decoupled from any UI / clipboard
/// concern so the formatting can be unit-tested without AppKit.
public struct TesterFeedbackComment: Sendable {
    public struct Input: Sendable {
        /// Self-declared subscription tier on the account being tested.
        public enum Plan: String, Sendable, CaseIterable {
            case free, pro, team, enterprise, other
        }

        /// One Verified-checklist item from the sign-off template.
        public struct ChecklistItem: Sendable {
            public let label: String
            public let confirmed: Bool

            public init(label: String, confirmed: Bool) {
                self.label = label
                self.confirmed = confirmed
            }
        }

        public let plan: Plan
        public let planOtherDescription: String?
        public let macOSVersion: String
        public let context: TesterFeedbackContext
        public let submissionPath: SubmissionPath
        public let checklist: [ChecklistItem]
        public let connectorLogAttached: Bool
        public let notes: String

        public init(
            plan: Plan,
            planOtherDescription: String? = nil,
            macOSVersion: String,
            context: TesterFeedbackContext,
            submissionPath: SubmissionPath,
            checklist: [ChecklistItem],
            connectorLogAttached: Bool,
            notes: String = ""
        ) {
            self.plan = plan
            self.planOtherDescription = planOtherDescription
            self.macOSVersion = macOSVersion
            self.context = context
            self.submissionPath = submissionPath
            self.checklist = checklist
            self.connectorLogAttached = connectorLogAttached
            self.notes = notes
        }
    }

    /// Path the tester used to produce the comment. Recorded in the
    /// rendered body so the maintainer can correlate UX bugs with the
    /// in-app flow.
    public enum SubmissionPath: String, Sendable {
        case inApp = "in-app"
        case manual
    }

    public static let sentinel = "✅ tester-confirm"
    public static let notesCharacterCap = 2_048

    /// Cap on the appended connector log tail. GitHub comments hard-cap at
    /// 65_536 characters; 30 KB leaves headroom for the rest of the body and
    /// avoids upload truncation on the maintainer's side.
    public static let logTailByteCap = 30_000

    /// Renders the sign-off comment with the log tail appended inside a
    /// collapsed `<details>` block so GitHub renders it as an expandable
    /// section — keeps the visible comment compact while preserving full
    /// context. Blank lines around the fenced block are required for
    /// GitHub Markdown to render it inside the HTML container.
    /// The block is omitted when contents are empty so the maintainer is
    /// not misled into thinking a log was attached.
    public static func renderWithLogTail(
        _ input: Input,
        logFileContents: String,
        tailByteCap: Int = logTailByteCap
    ) -> String {
        let body = render(input)
        let tail = trimmedLogTail(logFileContents, byteCap: tailByteCap)
        guard !tail.isEmpty else { return body }
        return body
            + "\n\n<details>\n<summary>Connector log tail</summary>\n\n"
            + "```log\n\(tail)\n```"
            + "\n\n</details>"
    }

    /// Returns the tail of `contents` capped to `byteCap` UTF-8 bytes, snapped
    /// to a line boundary so the fenced block never starts mid-line.
    static func trimmedLogTail(_ contents: String, byteCap: Int) -> String {
        let trimmed = contents.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        let utf8 = trimmed.utf8
        if utf8.count <= byteCap { return trimmed }
        let dropCount = utf8.count - byteCap
        let cutIndex = utf8.index(utf8.startIndex, offsetBy: dropCount)
        let candidate = String(trimmed[cutIndex...])
        if let firstNewline = candidate.firstIndex(of: "\n") {
            return String(candidate[candidate.index(after: firstNewline)...])
        }
        return candidate
    }

    public static func render(_ input: Input) -> String {
        var lines: [String] = [sentinel, ""]
        lines.append("Plan: \(planLine(input))")
        lines.append("macOS: \(input.macOSVersion)")
        lines.append("Build SHA: \(input.context.shortCommit) (full: \(input.context.buildCommit))")
        lines.append("Submission path: \(input.submissionPath.rawValue)")
        lines.append("Verified:")
        for item in input.checklist {
            let marker = item.confirmed ? "x" : " "
            lines.append("- [\(marker)] \(item.label)")
        }
        lines.append("Connector log attached: \(input.connectorLogAttached ? "yes" : "no")")
        let trimmedNotes = String(input.notes.prefix(notesCharacterCap))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedNotes.isEmpty {
            lines.append("Notes: \(trimmedNotes)")
        }
        return lines.joined(separator: "\n")
    }

    private static func planLine(_ input: Input) -> String {
        switch input.plan {
        case .free:       return "Free"
        case .pro:        return "Pro"
        case .team:       return "Team"
        case .enterprise: return "Enterprise"
        case .other:
            let description = (input.planOtherDescription ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return description.isEmpty ? "Other" : "Other: \(description)"
        }
    }
}
