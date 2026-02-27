import SwiftUI

/// Update dialog sheet for prompting users to install new versions
struct UpdateSheet: View {
    @Environment(\.dismiss) var dismiss
    @ObservedObject var updateService = UpdateService.shared
    @AppStorage("autoUpdate") private var autoUpdate = false

    let update: AppVersion
    let appName = "SpeakType"

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack(alignment: .top, spacing: 16) {
                Image(nsImage: NSApplication.shared.applicationIconImage)
                    .resizable()
                    .frame(width: 80, height: 80)
                    .cornerRadius(16)
                    .shadow(color: .black.opacity(0.2), radius: 10, x: 0, y: 5)

                VStack(alignment: .leading, spacing: 6) {
                    Text("A new version of \(appName) is available!")
                        .font(Typography.headlineLarge)
                        .foregroundStyle(.primary)

                    Text(
                        "\(appName) \(update.version) is now available—you have \(AppVersion.currentVersion). Would you like to down…"
                    )
                    .font(Typography.bodyMedium)
                    .foregroundStyle(.secondary)
                }
            }
            .padding(24)

            // What's New
            VStack(alignment: .leading, spacing: 16) {
                Text("What's New in Version \(update.version)")
                    .font(Typography.headlineMedium)
                    .foregroundStyle(.primary)

                VStack(alignment: .leading, spacing: 8) {
                    ForEach(update.releaseNotes, id: \.self) { note in
                        HStack(alignment: .top, spacing: 8) {
                            Text("•")
                                .font(Typography.bodyMedium)
                                .foregroundStyle(.primary)
                            Text(note)
                                .font(Typography.bodyMedium)
                                .foregroundStyle(.primary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(nsColor: .controlBackgroundColor))
            .cornerRadius(12)
            .padding(.horizontal, 24)

            // Progress area (shown only while installing)
            if updateService.isInstalling {
                VStack(spacing: 10) {
                    ProgressView(value: updateService.installProgress)
                        .progressViewStyle(.linear)
                        .frame(maxWidth: .infinity)

                    Text(updateService.installStatus)
                        .font(Typography.bodySmall)
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 24)
                .padding(.top, 20)
            }

            // Error banner
            if let error = updateService.installError {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    Text(error)
                        .font(Typography.bodySmall)
                        .foregroundStyle(.primary)
                    Spacer()
                }
                .padding(12)
                .background(Color.orange.opacity(0.1))
                .cornerRadius(8)
                .padding(.horizontal, 24)
                .padding(.top, 12)
            }

            // Auto-update checkbox (hidden while installing)
            if !updateService.isInstalling {
                HStack(spacing: 8) {
                    Toggle(isOn: $autoUpdate) {
                        Text("Automatically download and install updates in the future")
                            .font(Typography.bodySmall)
                            .foregroundStyle(.secondary)
                    }
                    .toggleStyle(.checkbox)
                }
                .padding(.horizontal, 24)
                .padding(.top, 20)
            }

            // Action buttons
            HStack(spacing: 12) {
                if updateService.isInstalling {
                    // Show only a disabled cancel-style placeholder while work is in progress
                    Text("Installing update, please wait…")
                        .font(Typography.bodySmall)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity)
                } else {
                    Button("Skip This Version") {
                        updateService.skipVersion(update.version)
                        dismiss()
                    }
                    .buttonStyle(SecondaryButtonStyle())

                    Button("Remind Me Later") {
                        updateService.markReminderShown()
                        dismiss()
                    }
                    .buttonStyle(SecondaryButtonStyle())

                    Button("Install Update") {
                        updateService.installUpdate(url: update.downloadURL)
                    }
                    .buttonStyle(PrimaryButtonStyle())
                    .disabled(updateService.isInstalling)
                }
            }
            .padding(24)
        }
        .frame(width: 600)
        .background(Color(nsColor: .windowBackgroundColor))
        // Allow the sheet to grow for the progress area
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

// MARK: - Preview

#Preview {
    UpdateSheet(update: AppVersion.mockUpdate)
        .frame(width: 600)
}
