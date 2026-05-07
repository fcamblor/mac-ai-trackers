import Foundation
import Testing
@testable import AIUsagesTrackersLib

@Suite("TesterFeedbackComment")
struct TesterFeedbackCommentTests {
    private let validCommit = String(repeating: "a", count: 40)

    private func makeContext() throws -> TesterFeedbackContext {
        // swiftlint:disable:next force_unwrapping
        let url = URL(string: "https://github.com/owner/repo/issues/42")!
        return TesterFeedbackContext(vendor: .claude, buildCommit: validCommit, issueURL: url)
    }

    @Test("renders the sentinel as the very first line")
    func startsWithSentinel() throws {
        let body = TesterFeedbackComment.render(.init(
            plan: .pro,
            macOSVersion: "15.4",
            context: try makeContext(),
            submissionPath: .inApp,
            checklist: [],
            connectorLogAttached: true
        ))
        #expect(body.hasPrefix("\(TesterFeedbackComment.sentinel)\n"))
    }

    @Test("includes both short and full commit SHA on the build line")
    func bothCommitFormsShown() throws {
        let body = TesterFeedbackComment.render(.init(
            plan: .pro,
            macOSVersion: "15.4",
            context: try makeContext(),
            submissionPath: .inApp,
            checklist: [],
            connectorLogAttached: true
        ))
        #expect(body.contains("Build SHA: aaaaaaaa (full: \(validCommit))"))
    }

    @Test("plan dropdown maps to the documented labels")
    func planLabels() throws {
        let context = try makeContext()
        for (plan, expected) in [
            (TesterFeedbackComment.Input.Plan.free, "Free"),
            (.pro, "Pro"),
            (.team, "Team"),
            (.enterprise, "Enterprise"),
        ] {
            let body = TesterFeedbackComment.render(.init(
                plan: plan,
                macOSVersion: "15.4",
                context: context,
                submissionPath: .inApp,
                checklist: [],
                connectorLogAttached: true
            ))
            #expect(body.contains("Plan: \(expected)"))
        }
    }

    @Test("plan = .other appends the description when present")
    func planOtherWithDescription() throws {
        let body = TesterFeedbackComment.render(.init(
            plan: .other,
            planOtherDescription: " Edu  ",
            macOSVersion: "15.4",
            context: try makeContext(),
            submissionPath: .inApp,
            checklist: [],
            connectorLogAttached: true
        ))
        #expect(body.contains("Plan: Other: Edu"))
    }

    @Test("plan = .other with empty description falls back to bare 'Other'")
    func planOtherWithoutDescription() throws {
        let body = TesterFeedbackComment.render(.init(
            plan: .other,
            planOtherDescription: "  ",
            macOSVersion: "15.4",
            context: try makeContext(),
            submissionPath: .inApp,
            checklist: [],
            connectorLogAttached: true
        ))
        #expect(body.contains("Plan: Other\n"))
    }

    @Test("checklist items render as `- [x]` / `- [ ]` matching the confirmation flag")
    func checklistMarkers() throws {
        let body = TesterFeedbackComment.render(.init(
            plan: .pro,
            macOSVersion: "15.4",
            context: try makeContext(),
            submissionPath: .inApp,
            checklist: [
                .init(label: "Active account is detected correctly", confirmed: true),
                .init(label: "Reset date matches", confirmed: false),
            ],
            connectorLogAttached: true
        ))
        #expect(body.contains("- [x] Active account is detected correctly"))
        #expect(body.contains("- [ ] Reset date matches"))
    }

    @Test("connector-log line reflects the attached flag")
    func connectorLogLine() throws {
        let attached = TesterFeedbackComment.render(.init(
            plan: .pro,
            macOSVersion: "15.4",
            context: try makeContext(),
            submissionPath: .inApp,
            checklist: [],
            connectorLogAttached: true
        ))
        #expect(attached.contains("Connector log attached: yes"))

        let absent = TesterFeedbackComment.render(.init(
            plan: .pro,
            macOSVersion: "15.4",
            context: try makeContext(),
            submissionPath: .inApp,
            checklist: [],
            connectorLogAttached: false
        ))
        #expect(absent.contains("Connector log attached: no"))
    }

    @Test("notes are emitted only when non-empty after trim")
    func notesEmission() throws {
        let withNotes = TesterFeedbackComment.render(.init(
            plan: .pro,
            macOSVersion: "15.4",
            context: try makeContext(),
            submissionPath: .inApp,
            checklist: [],
            connectorLogAttached: true,
            notes: "  one short observation  "
        ))
        #expect(withNotes.contains("Notes: one short observation"))

        let blank = TesterFeedbackComment.render(.init(
            plan: .pro,
            macOSVersion: "15.4",
            context: try makeContext(),
            submissionPath: .inApp,
            checklist: [],
            connectorLogAttached: true,
            notes: "   "
        ))
        #expect(!blank.contains("Notes:"))
    }

    @Test("notes longer than the cap are truncated, not rejected")
    func notesTruncation() throws {
        let huge = String(repeating: "x", count: TesterFeedbackComment.notesCharacterCap + 500)
        let body = TesterFeedbackComment.render(.init(
            plan: .pro,
            macOSVersion: "15.4",
            context: try makeContext(),
            submissionPath: .inApp,
            checklist: [],
            connectorLogAttached: true,
            notes: huge
        ))
        // Notes line emitted but capped at the limit (the cap excludes the
        // `Notes: ` prefix itself).
        guard let notesLine = body.split(separator: "\n").first(where: { $0.hasPrefix("Notes: ") }) else {
            Issue.record("Notes line missing")
            return
        }
        let payload = notesLine.dropFirst("Notes: ".count)
        #expect(payload.count == TesterFeedbackComment.notesCharacterCap)
    }
}
