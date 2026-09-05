import SwiftUI

/// Screen for managing AI transcription models
struct AIModelsView: View {
    // MARK: - Properties

    @StateObject private var downloadService = ModelManager.shared
    @AppStorage("selectedModelVariant") private var selectedModel: String = ""
    @State private var hasRefreshed = false
    private let models = AIModel.availableModels

    // MARK: - Computed Properties

    var selectedModelName: String {
        models.first(where: { $0.variant == selectedModel })?.name ?? "No model selected"
    }

    private var hasAnyModelDownloaded: Bool {
        downloadService.hasAnyDownloadedModel
    }

    // MARK: - Body

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                headerSection

                if hasRefreshed {
                    // Show setup banner if no model downloaded
                    if !hasAnyModelDownloaded {
                        setupBanner
                    }

                    currentModelCard
                    modelsListSection
                } else {
                    ProgressView("Checking downloaded models…")
                        .frame(maxWidth: .infinity, minHeight: 160)
                }
            }
            .padding(.horizontal, 24)
            .padding(.top, 20)
            .padding(.bottom, 24)
        }
        .background(Color.clear)
        .task {
            await downloadService.refreshDownloadedModels()
            reconcileSelection()
            hasRefreshed = true
        }
    }

    // MARK: - Subviews

    private var headerSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("AI Models")
                .font(Typography.displayLarge)
                .foregroundStyle(Color.textPrimary)

            HStack(spacing: 6) {
                let recommended = AIModel.recommendedModel(
                    forDeviceRAMGB: WhisperService.deviceRAMGB)
                Text(
                    "Recommended for your Mac (\(WhisperService.deviceRAMGB)GB RAM): **\(recommended.name)**"
                )
                .font(Typography.bodySmall)
                .foregroundStyle(Color.textSecondary)

                // Info icon with tooltip on hover
                Image(systemName: "info.circle")
                    .font(.system(size: 12))
                    .foregroundStyle(Color.textMuted)
                    .help(
                        "First transcription after selecting a model may take 10-30 seconds while the AI loads."
                    )
            }
        }
    }

    private var currentModelCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Default Model")
                .font(Typography.captionSmall)
                .foregroundStyle(Color.textSecondary)
                .textCase(.uppercase)
                .tracking(0.5)

            Text(selectedModelName)
                .font(Typography.headlineMedium)
                .foregroundStyle(Color.textPrimary)
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.bgCard)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color.border.opacity(0.5), lineWidth: 1)
        )
        .cardShadow()
    }

    private var modelsListSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Available Models")
                .font(Typography.headlineLarge)
                .foregroundStyle(Color.textPrimary)

            VStack(spacing: 12) {
                ForEach(models) { model in
                    ModelRow(
                        model: model,
                        selectedModel: $selectedModel,
                        onDeleted: { reconcileSelection() }
                    )
                }
            }
        }
    }

    private func reconcileSelection() {
        selectedModel = Self.reconciledSelection(
            current: selectedModel,
            models: models,
            isDownloaded: downloadService.isDownloaded(variant:)
        )
    }

    /// Keep a valid selection. If its files disappeared, choose the first
    /// downloaded model in visible catalog order rather than Dictionary order.
    static func reconciledSelection(
        current: String,
        models: [AIModel],
        isDownloaded: (String) -> Bool
    ) -> String {
        if !current.isEmpty, isDownloaded(current) { return current }
        return models.first(where: { isDownloaded($0.variant) })?.variant ?? ""
    }

    private var setupBanner: some View {
        HStack(spacing: 16) {
            Image(systemName: "arrow.down.circle.fill")
                .font(.system(size: 32))
                .foregroundStyle(Color.textPrimary)

            VStack(alignment: .leading, spacing: 4) {
                Text("Download a Model to Get Started")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Color.textPrimary)

                Text(
                    "Choose a model below to enable voice transcription. We recommend "
                        + "**\(AIModel.recommendedModel(forDeviceRAMGB: WhisperService.deviceRAMGB).name)** "
                        + "for your Mac."
                )
                .font(.system(size: 13))
                .foregroundStyle(Color.textSecondary)
            }

            Spacer()
        }
        .padding(20)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.textPrimary.opacity(0.05))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color.textPrimary.opacity(0.1), lineWidth: 1)
        )
    }
}

// MARK: - Preview

#Preview {
    AIModelsView()
        .background(Color.black)
}
