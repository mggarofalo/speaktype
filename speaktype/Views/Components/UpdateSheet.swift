import SwiftUI

/// Informational dialog for a newer source tag. SpeakType does not publish an installer.
struct UpdateSheet: View {
    @ObservedObject private var updateService = UpdateService.shared
    @AppStorage("autoUpdate") private var automaticChecks = false

    let update: AppVersion
    let onDismiss: () -> Void
    private let appName = "SpeakType"

    init(update: AppVersion, onDismiss: @escaping () -> Void = {}) {
        self.update = update
        self.onDismiss = onDismiss
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top, spacing: 16) {
                Image(nsImage: NSApplication.shared.applicationIconImage)
                    .resizable()
                    .frame(width: 80, height: 80)
                    .cornerRadius(16)
                    .shadow(color: .black.opacity(0.2), radius: 10, x: 0, y: 5)

                VStack(alignment: .leading, spacing: 6) {
                    Text("A new version of \(appName) is available")
                        .font(Typography.headlineLarge)
                        .foregroundStyle(.primary)

                    Text(
                        "\(appName) \(update.version) has been tagged. You currently have \(AppVersion.currentVersion)."
                    )
                    .font(Typography.bodyMedium)
                    .foregroundStyle(.secondary)
                }
            }
            .padding(24)

            VStack(alignment: .leading, spacing: 12) {
                Label("Source release", systemImage: "chevron.left.forwardslash.chevron.right")
                    .font(Typography.headlineMedium)
                    .foregroundStyle(.primary)

                Text(
                    """
                    This repository publishes version tags without a downloadable installer. \
                    Open \(update.tagName) on GitHub to review the source and build the update.
                    """
                )
                .font(Typography.bodyMedium)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(nsColor: .controlBackgroundColor))
            .cornerRadius(12)
            .padding(.horizontal, 24)

            Toggle(isOn: $automaticChecks) {
                Text("Automatically check for new version tags")
                    .font(Typography.bodySmall)
                    .foregroundStyle(.secondary)
            }
            .toggleStyle(.checkbox)
            .padding(.horizontal, 24)
            .padding(.top, 20)

            HStack(spacing: 12) {
                Button("Skip This Version") {
                    updateService.skipVersion(update.version)
                    onDismiss()
                }
                .buttonStyle(SecondaryButtonStyle())

                Button("Remind Me Later") {
                    updateService.markReminderShown()
                    onDismiss()
                }
                .buttonStyle(SecondaryButtonStyle())

                Link("View Source on GitHub", destination: update.sourceURL)
                    .buttonStyle(PrimaryButtonStyle())
                    .accessibilityHint("Opens the tagged source in your web browser")
            }
            .padding(24)
        }
        .frame(width: 600)
        .background(Color(nsColor: .windowBackgroundColor))
        .fixedSize(horizontal: false, vertical: true)
    }
}

// MARK: - Button Styles

struct PrimaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(Typography.labelMedium)
            .foregroundStyle(.white)
            .padding(.horizontal, 24)
            .padding(.vertical, 10)
            .background(Color.blue)
            .cornerRadius(8)
            .opacity(configuration.isPressed ? 0.8 : 1.0)
    }
}

struct SecondaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(Typography.labelMedium)
            .foregroundStyle(.primary)
            .padding(.horizontal, 24)
            .padding(.vertical, 10)
            .background(Color(nsColor: .controlBackgroundColor))
            .cornerRadius(8)
            .opacity(configuration.isPressed ? 0.8 : 1.0)
    }
}

#Preview {
    UpdateSheet(update: AppVersion.mockUpdate)
        .frame(width: 600)
}
