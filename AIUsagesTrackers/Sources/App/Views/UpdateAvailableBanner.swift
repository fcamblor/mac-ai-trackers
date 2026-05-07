import SwiftUI
import AIUsagesTrackersLib

struct UpdateAvailableBanner: View {
    let update: AvailableUpdate
    let installationKind: InstallationKind?
    let phase: UpdateState.Phase
    let onInstall: () -> Void
    let onRestart: () -> Void
    let onSkip: () -> Void
    let onLater: () -> Void

    private var primaryActionLabel: String {
        switch installationKind {
        case .homebrewCask: return "Update via Homebrew"
        case .manual, .none: return "Install update"
        }
    }

    private var subtitle: String {
        switch installationKind {
        case .homebrewCask:
            return "A new version is available. AI Usages Tracker will be reinstalled via Homebrew."
        case .manual, .none:
            return "A new version is available. macOS may ask for your administrator password if the app lives in a protected location."
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: bannerIconName)
                    .foregroundStyle(.tint)
                Text(bannerTitle)
                    .font(.system(size: 11, weight: .bold))
                    .textCase(.uppercase)
                Spacer()
                Text(update.version.rawValue)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
            }

            switch phase {
            case .preparing, .downloading, .verifying, .extracting, .runningHomebrew:
                inProgressSection
            case .readyToRestart:
                readyToRestartSection
            case .restarting:
                restartingSection
            case .failed(let message):
                failureSection(message: message)
            case .idle, .checking:
                idleSection
            }
        }
        .padding(8)
        .background(Color.accentColor.opacity(0.10), in: RoundedRectangle(cornerRadius: 6))
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .strokeBorder(Color.accentColor.opacity(0.30), lineWidth: 1)
        )
    }

    // MARK: - Sections

    private var idleSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(subtitle)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 8) {
                Button(primaryActionLabel) { onInstall() }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)

                Button("Later") { onLater() }
                    .buttonStyle(.bordered)
                    .controlSize(.small)

                Spacer()

                Button {
                    NSWorkspace.shared.open(update.releaseURL)
                } label: {
                    Image(systemName: "arrow.up.right.square")
                }
                .buttonStyle(.borderless)
                .help("Open release notes")

                Button {
                    onSkip()
                } label: {
                    Text("Skip")
                        .font(.system(size: 11))
                }
                .buttonStyle(.borderless)
                .help("Skip this version")
            }
        }
    }

    private var inProgressSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                ProgressView().controlSize(.small).scaleEffect(0.7)
                Text(progressStatusText)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
            }
            if let fraction = downloadProgressFraction {
                ProgressView(value: fraction)
                    .progressViewStyle(.linear)
            } else if case .downloading = phase {
                ProgressView()
                    .progressViewStyle(.linear)
            }
            if let detail = progressDetailText {
                Text(detail)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
        }
    }

    private var readyToRestartSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Update ready. Click Restart to apply it now.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 8) {
                Button("Restart now") { onRestart() }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                Button("Later") { onLater() }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                Spacer()
            }
        }
    }

    private var restartingSection: some View {
        HStack(spacing: 6) {
            ProgressView().controlSize(.small).scaleEffect(0.7)
            Text("Restarting…")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            Spacer()
        }
    }

    private func failureSection(message: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Update failed")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.red)
            Text(message)
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .lineLimit(3)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                Button("Retry") { onInstall() }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                Button("Later") { onLater() }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                Spacer()
            }
        }
    }

    // MARK: - Helpers

    private var bannerIconName: String {
        switch phase {
        case .failed: return "exclamationmark.triangle.fill"
        case .readyToRestart: return "checkmark.circle.fill"
        default: return "arrow.down.circle.fill"
        }
    }

    private var bannerTitle: String {
        switch phase {
        case .failed: return "Update failed"
        case .readyToRestart: return "Update ready"
        case .restarting: return "Restarting"
        case .preparing, .downloading, .verifying, .extracting, .runningHomebrew: return "Updating"
        case .idle, .checking: return "Update available"
        }
    }

    private var progressStatusText: String {
        switch phase {
        case .preparing: return "Preparing…"
        case .downloading: return "Downloading update…"
        case .verifying: return "Verifying download…"
        case .extracting: return "Extracting…"
        case .runningHomebrew: return "Running brew upgrade…"
        default: return ""
        }
    }

    private var progressDetailText: String? {
        switch phase {
        case .downloading(let received, let total):
            return Self.formatBytesProgress(received: received, total: total)
        case .runningHomebrew(let line):
            return line
        default:
            return nil
        }
    }

    private var downloadProgressFraction: Double? {
        if case .downloading(let received, let total) = phase, let total, total > 0 {
            return min(1.0, max(0.0, Double(received) / Double(total)))
        }
        return nil
    }

    private static func formatBytesProgress(received: Int64, total: Int64?) -> String {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useMB, .useKB, .useGB]
        formatter.countStyle = .file
        let receivedStr = formatter.string(fromByteCount: received)
        if let total, total > 0 {
            let totalStr = formatter.string(fromByteCount: total)
            return "\(receivedStr) of \(totalStr)"
        }
        return receivedStr
    }
}
