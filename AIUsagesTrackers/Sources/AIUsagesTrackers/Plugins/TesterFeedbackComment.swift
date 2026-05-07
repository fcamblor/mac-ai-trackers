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
