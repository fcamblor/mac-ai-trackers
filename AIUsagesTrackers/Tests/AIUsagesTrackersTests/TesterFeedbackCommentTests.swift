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

    @Test("renderWithLogTail wraps the log in a collapsed <details> block")
    func renderWithLogTailAppendsFencedBlock() throws {
        let body = TesterFeedbackComment.renderWithLogTail(
            .init(
                plan: .pro,
                macOSVersion: "15.4",
                context: try makeContext(),
                submissionPath: .inApp,
                checklist: [],
                connectorLogAttached: true
            ),
            logFileContents: "line-1\nline-2\nline-3\n"
        )
        // GitHub Markdown requires blank lines around the fenced block so
        // the <details> container renders the code block instead of HTML.
        #expect(body.contains("<details>\n<summary>Connector log tail</summary>\n\n```log\nline-1\nline-2\nline-3\n```\n\n</details>"))
    }

    @Test("renderWithLogTail omits the log block when contents are blank")
    func renderWithLogTailSkipsEmpty() throws {
        let body = TesterFeedbackComment.renderWithLogTail(
            .init(
                plan: .pro,
                macOSVersion: "15.4",
                context: try makeContext(),
                submissionPath: .inApp,
                checklist: [],
                connectorLogAttached: false
            ),
            logFileContents: "   \n\n   "
        )
        #expect(!body.contains("```log"))
    }

    @Test("trimmedLogTail caps to byteCap and snaps to a line boundary")
    func trimmedLogTailSnapsToLineBoundary() {
        // 100 lines of "0123456789" (10 chars + newline = 11 bytes) → 1100 bytes
        let lines = (0..<100).map { _ in "0123456789" }.joined(separator: "\n")
        let tail = TesterFeedbackComment.trimmedLogTail(lines, byteCap: 50)
        // Capped: each preserved line is intact (no mid-line cut) and total ≤ cap-ish
        for line in tail.split(separator: "\n") {
            #expect(line == "0123456789")
        }
        #expect(tail.utf8.count <= 50)
    }

    @Test("trimmedLogTail returns the full content when smaller than byteCap")
    func trimmedLogTailKeepsSmallContent() {
        let original = "abc\ndef\n"
        let tail = TesterFeedbackComment.trimmedLogTail(original, byteCap: 1_000)
        // The whitespace trimmer strips the trailing newline.
        #expect(tail == "abc\ndef")
    }
}
