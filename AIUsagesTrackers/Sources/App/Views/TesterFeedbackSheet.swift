import SwiftUI
import AppKit
import AIUsagesTrackersLib

/// Sheet hosting the tester sign-off form. Composes a comment body,
/// copies it to the system pasteboard, opens the GitHub issue in the
/// default browser, and reveals the connector log in Finder so the
/// tester can drag-attach it. See `docs/ASSISTANT-ONBOARDING.md` §6.4.
///
/// The form is intentionally feature-light: no GitHub authentication,
/// no log-file scanning (the connector's `PayloadSanitizing` is the
/// single source of truth for what counts as confidential), no
/// posting via the GitHub REST API. The browser hand-off is the
/// simplest reliable bridge that does not introduce a credential
/// surface area.
struct TesterFeedbackSheet: View {
    let context: TesterFeedbackContext
    let displayName: String
    let macOSVersion: String
    let connectorLogURL: URL
    let onDismiss: () -> Void
    let submitter: TesterFeedbackSubmitting

    @State private var plan: TesterFeedbackComment.Input.Plan = .pro
    @State private var planOtherDescription: String = ""
    @State private var checklistStates: [Bool]
    @State private var notes: String = ""
    @State private var didSubmit: Bool = false

    init(
        context: TesterFeedbackContext,
        displayName: String,
        macOSVersion: String,
        connectorLogURL: URL,
        submitter: TesterFeedbackSubmitting = SystemTesterFeedbackSubmitter(),
        onDismiss: @escaping () -> Void
    ) {
        self.context = context
        self.displayName = displayName
        self.macOSVersion = macOSVersion
        self.connectorLogURL = connectorLogURL
        self.submitter = submitter
        self.onDismiss = onDismiss
        _checklistStates = State(initialValue: Array(repeating: false, count: Self.checklistLabels.count))
    }

    private static let checklistLabels: [String] = [
        "Active account is detected correctly",
        "At least one usage metric matches the vendor's own dashboard within reasonable tolerance",
        "Reset date displayed in the popover matches the vendor's reported reset",
        "Optional: outage banner appears when the vendor reports an incident",
    ]

    private static let sheetWidth: CGFloat = 480
    private static let notesCharacterCap = TesterFeedbackComment.notesCharacterCap

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            Divider()
            buildLine
            planPicker
            macOSLine
            checklist
            connectorLogLine
            notesField
            preview
            Divider()
            footer
        }
        .padding(16)
        .frame(width: Self.sheetWidth)
    }

    private var header: some View {
        HStack {
            Image(systemName: "flask")
                .foregroundStyle(.tint)
            Text("Submit tester feedback")
                .font(.system(size: 13, weight: .semibold))
            Spacer()
            Button {
                onDismiss()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.borderless)
        }
    }

    private var buildLine: some View {
        HStack(alignment: .firstTextBaseline) {
            Text("Build")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
            Text("\(displayName) · \(context.shortCommit)")
                .font(.system(size: 11))
            Spacer()
            Button("Copy full SHA") {
                submitter.copy(context.buildCommit)
            }
            .buttonStyle(.borderless)
            .controlSize(.small)
        }
    }

    private var planPicker: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Plan")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
            Picker("Plan", selection: $plan) {
                Text("Free").tag(TesterFeedbackComment.Input.Plan.free)
                Text("Pro").tag(TesterFeedbackComment.Input.Plan.pro)
                Text("Team").tag(TesterFeedbackComment.Input.Plan.team)
                Text("Enterprise").tag(TesterFeedbackComment.Input.Plan.enterprise)
                Text("Other").tag(TesterFeedbackComment.Input.Plan.other)
            }
            .labelsHidden()
            .pickerStyle(.menu)

            if plan == .other {
                TextField("Describe your plan", text: $planOtherDescription)
                    .textFieldStyle(.roundedBorder)
                    .controlSize(.small)
            }
        }
    }

    private var macOSLine: some View {
        HStack(alignment: .firstTextBaseline) {
            Text("macOS")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
            Text(macOSVersion)
                .font(.system(size: 11))
            Spacer()
        }
    }

    private var checklist: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Verified")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
            ForEach(Array(Self.checklistLabels.enumerated()), id: \.offset) { index, label in
                Toggle(isOn: bindingForChecklist(index)) {
                    Text(label)
                        .font(.system(size: 11))
                        .fixedSize(horizontal: false, vertical: true)
                }
                .toggleStyle(.checkbox)
            }
        }
    }

    private func bindingForChecklist(_ index: Int) -> Binding<Bool> {
        Binding(
            get: { checklistStates[index] },
            set: { checklistStates[index] = $0 }
        )
    }

    private var connectorLogLine: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Connector log")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
            HStack(alignment: .firstTextBaseline) {
                Text(connectorLogURL.path)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
                Button("Reveal in Finder") {
                    submitter.reveal(connectorLogURL)
                }
                .controlSize(.small)
            }
            Text("The log is sanitized — but if anything looks confidential, edit the file before drag-attaching, and flag it in your notes so we fix the sanitizer.")
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var notesField: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Notes (optional)")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
            TextField("Free-form, capped at \(Self.notesCharacterCap) chars", text: $notes, axis: .vertical)
                .lineLimit(3...5)
                .textFieldStyle(.roundedBorder)
                .onChange(of: notes) { _, newValue in
                    if newValue.count > Self.notesCharacterCap {
                        notes = String(newValue.prefix(Self.notesCharacterCap))
                    }
                }
        }
    }

    private var preview: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Preview")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
            ScrollView {
                Text(renderedComment)
                    .font(.system(size: 10, design: .monospaced))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
            }
            .frame(maxHeight: 140)
            .background(Color(NSColor.controlBackgroundColor), in: RoundedRectangle(cornerRadius: 4))
        }
    }

    private var footer: some View {
        HStack {
            if didSubmit {
                Text("Comment copied. Browser opened on the issue. Drag the highlighted log file into GitHub, then click Comment.")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Spacer()
            }
            Spacer()
            Button("Cancel") { onDismiss() }
                .keyboardShortcut(.cancelAction)
            Button {
                submit()
            } label: {
                Text(didSubmit ? "Re-open issue" : "Submit")
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.defaultAction)
        }
    }

    private var renderedComment: String {
        TesterFeedbackComment.render(currentInput)
    }

    private var currentInput: TesterFeedbackComment.Input {
        TesterFeedbackComment.Input(
            plan: plan,
            planOtherDescription: planOtherDescription,
            macOSVersion: macOSVersion,
            context: context,
            submissionPath: .inApp,
            checklist: zip(Self.checklistLabels, checklistStates).map {
                TesterFeedbackComment.Input.ChecklistItem(label: $0.0, confirmed: $0.1)
            },
            connectorLogAttached: true,
            notes: notes
        )
    }

    private func submit() {
        let body = renderedComment
        submitter.copy(body)
        submitter.openIssue(context.issueURL)
        submitter.reveal(connectorLogURL)
        didSubmit = true
    }
}

/// Side-effects the sheet needs to perform on submit, behind a protocol
/// so unit tests can verify the order and arguments without touching
/// the system pasteboard, the user's browser, or Finder.
public protocol TesterFeedbackSubmitting {
    func copy(_ text: String)
    func openIssue(_ url: URL)
    func reveal(_ fileURL: URL)
}

/// Production wiring: NSPasteboard for clipboard, NSWorkspace for the
/// browser hand-off and the Finder reveal. None of these calls block,
/// none of them require a GitHub credential.
public struct SystemTesterFeedbackSubmitter: TesterFeedbackSubmitting {
    public init() {}

    public func copy(_ text: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.declareTypes([.string], owner: nil)
        pasteboard.setString(text, forType: .string)
    }

    public func openIssue(_ url: URL) {
        // GitHub does not honor `?body=` on existing-issue URLs, so the
        // comment hand-off is via the clipboard. Appending the
        // `#issuecomment-new` fragment scrolls a logged-in browser
        // session to the comment composer.
        let target = URL(string: url.absoluteString + "#issuecomment-new") ?? url
        NSWorkspace.shared.open(target)
    }

    public func reveal(_ fileURL: URL) {
        NSWorkspace.shared.activateFileViewerSelecting([fileURL])
    }
}
