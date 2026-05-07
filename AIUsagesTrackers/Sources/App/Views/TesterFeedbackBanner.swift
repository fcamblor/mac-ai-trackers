import SwiftUI
import AIUsagesTrackersLib

/// Tester-only nudge displayed inside the popover when a tester DMG
/// (cf. `docs/ASSISTANT-ONBOARDING.md` §6.4) is running. Invisible by
/// construction in stable releases — the parent view passes a non-nil
/// context only when `TesterFeedbackContext.resolved` is non-nil, which
/// itself depends on three Info.plist keys never present in tagged
/// builds.
struct TesterFeedbackBanner: View {
    let context: TesterFeedbackContext
    let displayName: String
    let onSubmit: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "flask")
                .foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 2) {
                Text("Tester build for \(displayName)")
                    .font(.system(size: 11, weight: .semibold))
                Text("Commit \(context.shortCommit)")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button {
                onSubmit()
            } label: {
                Text("Submit feedback")
                    .font(.system(size: 11, weight: .medium))
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
        }
        .padding(8)
        .background(Color.accentColor.opacity(0.10), in: RoundedRectangle(cornerRadius: 6))
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .strokeBorder(Color.accentColor.opacity(0.30), lineWidth: 1)
        )
    }
}
