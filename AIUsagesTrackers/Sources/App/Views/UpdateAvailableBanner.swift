import SwiftUI
import AIUsagesTrackersLib

struct UpdateAvailableBanner: View {
    let update: AvailableUpdate
    let installationKind: InstallationKind?
    let isInstalling: Bool
    let onInstall: () -> Void
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
                Image(systemName: "arrow.down.circle.fill")
                    .foregroundStyle(.tint)
                Text("Update available")
                    .font(.system(size: 11, weight: .bold))
                    .textCase(.uppercase)
                Spacer()
                Text(update.version.rawValue)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
            }

            Text(subtitle)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 8) {
                Button {
                    onInstall()
                } label: {
                    HStack(spacing: 4) {
                        if isInstalling {
                            ProgressView().controlSize(.small).scaleEffect(0.6)
                        }
                        Text(primaryActionLabel)
                    }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .disabled(isInstalling)

                Button("Later") { onLater() }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(isInstalling)

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
                .disabled(isInstalling)
            }
        }
        .padding(8)
        .background(Color.accentColor.opacity(0.10), in: RoundedRectangle(cornerRadius: 6))
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .strokeBorder(Color.accentColor.opacity(0.30), lineWidth: 1)
        )
    }
}
