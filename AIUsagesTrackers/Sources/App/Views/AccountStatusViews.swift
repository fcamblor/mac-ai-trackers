import SwiftUI
import AIUsagesTrackersLib

// Account-level status pieces rendered around the metrics. Each view renders
// nothing for a nominal state so a healthy card looks exactly as before.

// MARK: - Header pieces

/// Neutral plan label next to the "active" capsule — the only coloured
/// capsule in the header stays the active one.
struct PlanCapsule: View {
    let plan: PlanType

    var body: some View {
        Text(plan.displayName)
            .font(.system(size: 9, weight: .medium))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .overlay(Capsule().strokeBorder(Color.primary.opacity(0.25), lineWidth: 1))
            .help("Plan: \(plan.displayName)")
    }
}

/// Count of redeemable "usage limit reset" tokens. Muted while none would
/// have an effect, so it reads as inventory rather than a call to action.
struct ResetCreditsBadge: View {
    let resetCredits: ResetCredits

    private var isApplicable: Bool { resetCredits.applicable > 0 }

    var body: some View {
        HStack(spacing: 2) {
            Image(systemName: "arrow.counterclockwise")
                .font(.system(size: 8, weight: .semibold))
            Text("\(resetCredits.available)")
                .font(.system(size: 9, weight: .medium).monospacedDigit())
        }
        .foregroundStyle(isApplicable ? Color.primary : Color.secondary.opacity(0.7))
        .help(helpText)
    }

    private var helpText: String {
        let noun = resetCredits.available == 1 ? "usage limit reset" : "usage limit resets"
        if isApplicable {
            return "\(resetCredits.available) \(noun) — \(resetCredits.applicable) usable now"
        }
        return "\(resetCredits.available) \(noun) — none usable right now"
    }
}

// MARK: - Block banner

/// Replaces the guesswork of a full gauge: states that requests are refused,
/// why, and when they resume.
struct AccountBlockBanner: View {
    let block: AccountBlock
    let resetCredits: ResetCredits?

    private static let bannerTint = Color.red

    var body: some View {
        TimelineView(.periodic(from: .now, by: 60)) { context in
            content(now: context.date)
        }
    }

    private func content(now: Date) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: iconName)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Self.bannerTint)
                .frame(width: 12, height: 12)

            VStack(alignment: .leading, spacing: 2) {
                Text(title(now: now))
                    .font(.system(size: 10, weight: .semibold))
                    .fixedSize(horizontal: false, vertical: true)
                if let detail = detail(now: now) {
                    Text(detail)
                        .font(.system(size: 9))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if block.reason == .rateLimit, let resetCredits, resetCredits.applicable > 0 {
                    Label(
                        "\(resetCredits.applicable) usage limit reset\(resetCredits.applicable == 1 ? "" : "s") available",
                        systemImage: "arrow.counterclockwise"
                    )
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(Self.bannerTint)
                }
            }
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Self.bannerTint.opacity(0.10), in: RoundedRectangle(cornerRadius: 6))
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .strokeBorder(Self.bannerTint.opacity(0.35), lineWidth: 1)
        )
    }

    private var iconName: String {
        block.reason == .spendControl ? "lock.fill" : "pause.circle.fill"
    }

    private func title(now: Date) -> String {
        if block.reason == .spendControl {
            return "Spending cap reached"
        }
        guard let resumesAt = block.resumesAt, let date = resumesAt.date, date > now else {
            return "Usage limit reached"
        }
        return "Usage limit reached · resumes at \(formatResumeTime(resumesAt, now: now))"
    }

    private func detail(now: Date) -> String? {
        if block.reason == .spendControl {
            return "Your organization's spending cap blocks new requests until an admin raises it."
        }
        guard let resumesAt = block.resumesAt, let date = resumesAt.date, date > now else { return nil }
        return "Requests are refused for \(formatRemainingTime(resetAt: resumesAt, now: now))."
    }
}

// MARK: - Model availability

/// One chip per model the vendor currently refuses. Hidden when every model
/// is available.
struct UnavailableModelsRow: View {
    let models: [ModelAvailability]

    var body: some View {
        TimelineView(.periodic(from: .now, by: 60)) { context in
            FlowingChips(models: models, now: context.date)
        }
    }

    private struct FlowingChips: View {
        let models: [ModelAvailability]
        let now: Date

        var body: some View {
            VStack(alignment: .leading, spacing: 4) {
                Text("Unavailable models")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                ForEach(models, id: \.model) { model in
                    HStack(spacing: 6) {
                        UnavailableModelChip(model: model, now: now)
                        if model.creditsWouldEnable {
                            Text("unlockable with credits")
                                .font(.system(size: 9))
                                .italic()
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
    }
}

private struct UnavailableModelChip: View {
    let model: ModelAvailability
    let now: Date

    var body: some View {
        HStack(spacing: 3) {
            Circle()
                .fill(Color.secondary.opacity(0.5))
                .frame(width: 5, height: 5)
            Text(label)
                .font(.system(size: 9, weight: .medium).monospacedDigit())
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(Color.secondary.opacity(0.12), in: Capsule())
        .help(helpText)
    }

    private var availableAgain: ISODate? {
        guard let availableAt = model.availableAt, let date = availableAt.date, date > now else { return nil }
        return availableAt
    }

    private var label: String {
        guard let availableAgain else { return model.model.rawValue }
        return "\(model.model.rawValue) · \(formatResumeTime(availableAgain, now: now))"
    }

    private var helpText: String {
        guard let availableAgain else { return "\(model.model.rawValue) is unavailable" }
        return "\(model.model.rawValue) is unavailable until \(formatResetDate(availableAgain, now: now))"
    }
}

// MARK: - Credits

/// Remaining-messages estimate and credit-limit states. The vendor returns a
/// [min, max] range; showing both bounds avoids implying false precision.
struct CreditsSummaryRow: View {
    let credits: CreditsSummary

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(credits.unlimited || credits.overageLimitReached ? "Credits" : "Messages left")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
            Spacer()
            Text(valueText)
                .font(.system(size: 11, weight: .semibold).monospacedDigit())
                .foregroundStyle(credits.overageLimitReached ? Color.orange : Color.primary)
                .multilineTextAlignment(.trailing)
        }
        .help(helpText)
    }

    private var valueText: String {
        if credits.unlimited { return "Unlimited" }
        if credits.overageLimitReached { return "Overage limit reached" }
        return [
            credits.approxLocalMessages.map { "\(Self.format($0)) local" },
            credits.approxCloudMessages.map { "\(Self.format($0)) cloud" },
        ]
        .compactMap { $0 }
        .joined(separator: " · ")
        .prefixedWithApproximation()
    }

    private var helpText: String {
        if credits.overageLimitReached {
            return "Credit overage limit reached — requests beyond the plan allowance are refused."
        }
        return "Approximate messages your remaining credits cover, as estimated by the vendor."
    }

    private static func format(_ range: MessageRange) -> String {
        range.lower == range.upper ? "\(range.lower)" : "\(range.lower)–\(range.upper)"
    }
}

private extension String {
    func prefixedWithApproximation() -> String { isEmpty ? self : "≈ \(self)" }
}
