import SwiftUI

struct HistoryView: View {
    @StateObject private var historyService = HistoryService.shared
    @StateObject private var browser = HistoryBrowser()
    @FocusState private var isSearchFocused: Bool
    @State private var showDeleteAlert = false
    @State private var itemPendingDeletion: HistoryItem?
    @State private var expandedItemID: UUID?
    @State private var showCopyToast = false
    @State private var retranscribingItemID: UUID?
    @State private var retranscribeError: String?
    @State private var dismissedServiceErrorRevision: Int?

    @AppStorage("transcriptionLanguage") private var transcriptionLanguage = "auto"
    @AppStorage("selectedModelVariant") private var selectedModel = ""
    private var whisperService: WhisperService { WhisperService.shared }

    var body: some View {
        ScrollView {
            VStack(spacing: 24) {
                header
                HStack(spacing: 8) {
                    Button { isSearchFocused = true } label: {
                        Image(systemName: "magnifyingglass")
                    }
                    .buttonStyle(.plain)
                    .keyboardShortcut("f", modifiers: .command)
                    .help("Search history (⌘F)")
                    .accessibilityLabel("Focus history search")
                    TextField("Search transcriptions", text: $browser.searchText)
                        .textFieldStyle(.plain)
                        .focused($isSearchFocused)
                        .onExitCommand { browser.searchText = "" }
                    if !browser.searchText.isEmpty {
                        Button { browser.searchText = "" } label: {
                            Image(systemName: "xmark.circle.fill")
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Clear search")
                    }
                }
                .padding(10)
                .background(Color.bgHover, in: RoundedRectangle(cornerRadius: 8))
                .padding(.horizontal, 24)
                if let recoveryError = historyService.recoveryErrorMessage {
                    HistoryRecoveryBanner(
                        pendingCount: historyService.pendingMutationCount,
                        message: recoveryError
                    ) {
                        historyService.retryPendingWrites()
                        Task {
                            await historyService.waitUntilReady()
                            await browser.refresh()
                        }
                    }
                }
                if !browser.rows.isEmpty, let errorMessage = activeError {
                    errorBanner(errorMessage)
                }
                if browser.isLoading && browser.rows.isEmpty {
                    ProgressView("Loading history…")
                        .frame(maxWidth: .infinity, minHeight: 260)
                } else if let errorMessage = activeError, browser.rows.isEmpty {
                    errorState(errorMessage)
                } else if browser.rows.isEmpty {
                    emptyState
                } else {
                    LazyVStack(spacing: 16) {
                        ForEach(browser.rows) { row in
                            HistoryCard(
                                row: row,
                                isExpanded: expandedItemID == row.id,
                                isRetranscribing: retranscribingItemID == row.id,
                                isAnyRetranscribing: retranscribingItemID != nil,
                                onToggle: { toggle(row.item) },
                                onQuickCopy: { copyToClipboard(text: row.item.transcript) },
                                onCopy: { copyToClipboard(text: row.item.transcript) },
                                onDelete: { itemPendingDeletion = row.item },
                                onRetranscribe: { retranscribe(row.item) }
                            )
                        }
                    }
                    .padding(.horizontal, 24)
                    pagination
                }
            }
            .padding(.bottom, 24)
        }
        .tint(Color.accentPrimary)
        .task { await browser.loadInitialPage() }
        .task(id: browser.searchText) {
            // `.task(id:)` cancels the previous debounce when the query changes.
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled else { return }
            stopPlaybackAndCollapse()
            await browser.search()
        }
        .onChange(of: historyService.revision) { _, _ in
            Task { await browser.refresh() }
        }
        .onDisappear { stopPlaybackAndCollapse() }
        .overlay(alignment: .bottom) { copyToast }
        .alert("Clear All History?", isPresented: $showDeleteAlert) {
            Button("Cancel", role: .cancel) { }
            Button("Clear All", role: .destructive) {
                stopPlaybackAndCollapse()
                historyService.clearAll()
                browser.resetToFirstPage()
                Task { await browser.search() }
            }
        } message: {
            Text("This removes saved transcripts from History. Your statistics history and saved audio recordings are kept.")
        }
        .alert(
            "Delete Transcript?",
            isPresented: Binding(
                get: { itemPendingDeletion != nil },
                set: { if !$0 { itemPendingDeletion = nil } }
            ),
            presenting: itemPendingDeletion
        ) { item in
            Button("Cancel", role: .cancel) { }
            Button("Delete", role: .destructive) {
                stopPlaybackAndCollapse()
                historyService.deleteItem(id: item.id)
                itemPendingDeletion = nil
                Task { await browser.refresh() }
            }
        } message: { _ in
            Text("This removes the transcript and its saved recording, if one is attached.")
        }
        .alert("Re-transcription Failed", isPresented: Binding(
            get: { retranscribeError != nil }, set: { if !$0 { retranscribeError = nil } }
        )) {
            Button("OK", role: .cancel) { }
        } message: {
            Text(retranscribeError ?? "")
        }
    }

    private var header: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 4) {
                Text("History")
                    .font(Typography.displayLarge)
                    .foregroundStyle(Color.textPrimary)
                if browser.totalCount > 0 {
                    Text("\(browser.totalCount) transcription\(browser.totalCount == 1 ? "" : "s")")
                        .font(Typography.bodySmall)
                        .foregroundStyle(Color.textSecondary)
                }
            }
            Spacer()
            if browser.totalCount > 0 {
                Button(role: .destructive) { showDeleteAlert = true } label: {
                    Label("Clear All", systemImage: "trash")
                }
                .buttonStyle(HistoryActionButtonStyle())
                .accessibilityLabel("Clear all history")
            }
        }
        .padding(.horizontal, 24)
        .padding(.top, 20)
    }

    private var activeError: String? {
        if let browserError = browser.errorMessage { return browserError }
        guard let serviceError = historyService.errorMessage,
              historyService.errorRevision != dismissedServiceErrorRevision
        else { return nil }
        return serviceError
    }

    private func errorBanner(_ message: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            Text(message)
                .font(Typography.bodySmall)
                .foregroundStyle(Color.textSecondary)
                .lineLimit(2)
            Spacer(minLength: 8)
            Button("Retry", action: retryLoading)
            Button("Dismiss", action: dismissError)
        }
        .padding(12)
        .background(Color.bgHover)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .padding(.horizontal, 24)
        .accessibilityLabel("History error: \(message)")
    }

    private var emptyState: some View {
        VStack(spacing: 20) {
            Image(systemName: browser.searchText.isEmpty ? "clock.badge.questionmark" : "magnifyingglass")
                .font(.system(size: 56))
                .foregroundStyle(Color.textMuted.opacity(0.4))
            VStack(spacing: 8) {
                Text(browser.searchText.isEmpty ? "No transcriptions yet" : "No matching transcriptions")
                    .font(Typography.displaySmall)
                    .foregroundStyle(Color.textPrimary)
                if browser.searchText.isEmpty {
                    Text("Use your recording shortcut to start recording.")
                        .font(Typography.bodyMedium)
                        .foregroundStyle(Color.textSecondary)
                } else {
                    Button("Clear Search") { browser.searchText = "" }
                        .accessibilityLabel("Clear history search")
                }
            }
        }
        .frame(maxWidth: .infinity, minHeight: 260)
    }

    private func errorState(_ message: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 36))
                .foregroundStyle(Color.textMuted)
            Text("Couldn’t load history").font(Typography.displaySmall)
            Text(message)
                .font(Typography.bodySmall)
                .foregroundStyle(Color.textSecondary)
                .multilineTextAlignment(.center)
            HStack {
                Button("Try Again", action: retryLoading)
                Button("Dismiss", action: dismissError)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 260)
    }

    private var pagination: some View {
        HStack(spacing: 14) {
            Button { changePage(previous: true) } label: {
                Label("Previous", systemImage: "chevron.left")
            }
            .disabled(!browser.canGoBack || browser.isLoading)
            .accessibilityLabel("Previous history page")
            Text("Page \(browser.pageNumber) of \(browser.pageCount)")
                .font(Typography.bodySmall)
                .foregroundStyle(Color.textSecondary)
                .monospacedDigit()
            Button { changePage(previous: false) } label: {
                Label("Next", systemImage: "chevron.right")
            }
            .disabled(!browser.canGoForward || browser.isLoading)
            .accessibilityLabel("Next history page")
        }
        .padding(.bottom, 8)
    }

    @ViewBuilder private var copyToast: some View {
        if showCopyToast {
            HStack(spacing: 8) {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(Color.accentBlue)
                Text("Text Copied").font(Typography.labelMedium).foregroundStyle(.white)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .background(Material.ultraThinMaterial)
            .background(Color.black.opacity(0.8))
            .clipShape(Capsule())
            .shadow(radius: 10)
            .padding(.bottom, 30)
            .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }

    private func changePage(previous: Bool) {
        stopPlaybackAndCollapse()
        Task {
            if previous { await browser.previousPage() }
            else { await browser.nextPage() }
        }
    }

    private func retryLoading() {
        dismissedServiceErrorRevision = nil
        if historyService.errorMessage != nil {
            historyService.retryLoading()
            Task {
                await historyService.waitUntilReady()
                await browser.refresh()
            }
        } else {
            Task { await browser.refresh() }
        }
    }

    private func dismissError() {
        browser.dismissError()
        dismissedServiceErrorRevision = historyService.errorRevision
    }

    private func toggle(_ item: HistoryItem) {
        withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
            if expandedItemID == item.id {
                expandedItemID = nil
                AudioPlayerService.shared.reset()
            } else {
                AudioPlayerService.shared.reset()
                expandedItemID = item.id
            }
        }
    }

    private func stopPlaybackAndCollapse() {
        expandedItemID = nil
        AudioPlayerService.shared.reset()
    }

    private func retranscribe(_ item: HistoryItem) {
        guard retranscribingItemID == nil, !TranscriptionLifecycle.shared.isTerminating else { return }
        // This action is only available from the expanded audio section.
        guard let audioURL = item.audioFileURL,
              FileManager.default.fileExists(atPath: audioURL.path)
        else {
            retranscribeError = "The original recording for this transcript is no longer available."
            return
        }
        let variant = selectedModel.isEmpty ? whisperService.currentModelVariant : selectedModel
        guard !variant.isEmpty else {
            retranscribeError = "No transcription model is selected."
            return
        }
        retranscribingItemID = item.id
        TranscriptionLifecycle.shared.perform {
            do {
                if !whisperService.isReadyToTranscribe(variant: variant) {
                    try await whisperService.loadModel(variant: variant)
                }
                let start = Date()
                let text = try await whisperService.transcribe(audioFile: audioURL, language: transcriptionLanguage)
                let elapsed = Date().timeIntervalSince(start)
                let modelName = AIModel.availableModels.first(where: { $0.variant == variant })?.name ?? variant
                guard !WhisperService.normalizedTranscription(from: text).isEmpty else {
                    retranscribeError = "No speech was detected in the recording."
                    retranscribingItemID = nil
                    return
                }
                historyService.updateTranscript(id: item.id, transcript: text, modelUsed: modelName, transcriptionTime: elapsed)
                retranscribingItemID = nil
                await browser.refresh()
            } catch {
                retranscribingItemID = nil
                retranscribeError = error.localizedDescription
            }
        }
    }

    private func copyToClipboard(text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        withAnimation { showCopyToast = true }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            withAnimation { showCopyToast = false }
        }
    }
}

private struct HistoryCard: View {
    let row: HistoryRow
    let isExpanded: Bool
    let isRetranscribing: Bool
    let isAnyRetranscribing: Bool
    let onToggle: () -> Void
    let onQuickCopy: () -> Void
    let onCopy: () -> Void
    let onDelete: () -> Void
    let onRetranscribe: () -> Void
    @State private var isHovered = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .center, spacing: 12) {
                Button(action: onToggle) {
                    HStack(spacing: 16) {
                        dateBadge
                        VStack(alignment: .leading, spacing: 8) {
                            Text(row.preview)
                                .font(Typography.bodyMedium)
                                .foregroundStyle(Color.textPrimary)
                                .lineLimit(2)
                                .lineSpacing(4)
                            metadata
                        }
                        Spacer(minLength: 0)
                        Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                            .font(.system(size: 12))
                            .foregroundStyle(Color.textMuted)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(isExpanded ? "Collapse transcription" : "Expand transcription")
                Button(action: onQuickCopy) {
                    Image(systemName: "doc.on.doc")
                        .font(.system(size: 13))
                        .padding(8)
                        .background(Color.bgHover)
                        .clipShape(RoundedRectangle(cornerRadius: 7))
                }
                .buttonStyle(.plain)
                .help("Copy transcription")
                .accessibilityLabel("Copy transcription")
            }
            .padding(20)
            if isExpanded {
                ExpandedHistoryContent(
                    item: row.item,
                    isRetranscribing: isRetranscribing,
                    isAnyRetranscribing: isAnyRetranscribing,
                    onCopy: onCopy,
                    onDelete: onDelete,
                    onRetranscribe: onRetranscribe
                )
            }
        }
        .background(Color.bgCard)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12)
            .stroke(isHovered || isExpanded ? Color.border : Color.border.opacity(0.5), lineWidth: 1))
        .cardShadow()
        .onHover { isHovered = $0 }
    }

    private var dateBadge: some View {
        VStack(spacing: 2) {
            Text(row.item.date.formatted(.dateTime.day()))
                .font(.system(size: 18, weight: .semibold, design: .serif))
                .foregroundStyle(Color.textPrimary)
            Text(row.item.date.formatted(.dateTime.month(.abbreviated)))
                .font(Typography.captionSmall)
                .foregroundStyle(Color.textMuted)
                .textCase(.uppercase)
        }
        .frame(width: 48)
    }

    private var metadata: some View {
        HStack(spacing: 8) {
            Label(row.item.date.formatted(date: .omitted, time: .shortened), systemImage: "clock")
            Text("•")
            Label("\(row.wordCount) words", systemImage: "text.word.spacing")
            Text("•")
            Label(durationText(row.item.duration), systemImage: "waveform")
        }
        .font(Typography.captionSmall)
        .foregroundStyle(Color.textMuted)
        .lineLimit(1)
    }
}

/// This is the only history subview that observes `AudioPlayerService`, so its
/// 10 Hz timer cannot invalidate the page, list, or collapsed cards.
private struct ExpandedHistoryContent: View {
    let item: HistoryItem
    let isRetranscribing: Bool
    let isAnyRetranscribing: Bool
    let onCopy: () -> Void
    let onDelete: () -> Void
    let onRetranscribe: () -> Void
    @StateObject private var audioPlayer = AudioPlayerService.shared
    @State private var audioURL: URL?
    @State private var audioChecked = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Divider()
            Text(item.transcript)
                .font(Typography.bodyLarge)
                .foregroundStyle(Color.textPrimary)
                .textSelection(.enabled)
                .lineSpacing(6)
            ViewThatFits(in: .horizontal) {
                actionButtons
                actionMenu
            }
            if let audioURL {
                playbackSection(audioURL)
            } else if audioChecked, item.audioFileURL != nil {
                Label("Audio file missing", systemImage: "exclamationmark.triangle")
                    .font(Typography.labelMedium)
                    .foregroundStyle(Color.textMuted)
            }
            if item.modelUsed != nil || item.detectedLanguage != nil {
                Divider()
                HStack(spacing: 12) {
                    if let model = item.modelUsed { Label(model, systemImage: "cpu") }
                    if let code = item.detectedLanguage {
                        Label(LanguagePreferences.displayName(for: code), systemImage: "globe")
                    }
                }
                .font(Typography.captionSmall)
                .foregroundStyle(Color.textMuted)
            }
        }
        .padding(.horizontal, 20)
        .padding(.bottom, 20)
        .task(id: item.id) {
            // The file system is intentionally not touched until this item expands.
            guard let candidate = item.audioFileURL,
                  FileManager.default.fileExists(atPath: candidate.path)
            else {
                audioURL = nil
                audioChecked = true
                return
            }
            audioURL = candidate
            audioChecked = true
            audioPlayer.loadAudio(from: candidate)
        }
    }

    private var actionButtons: some View {
        HStack(spacing: 12) {
            actionButton("Copy", icon: "doc.on.doc", action: onCopy)
            actionButton("Delete", icon: "trash", role: .destructive, action: onDelete)
            if audioURL != nil {
                Button(action: onRetranscribe) {
                    Label(isRetranscribing ? "Re-transcribing…" : "Re-transcribe", systemImage: "arrow.triangle.2.circlepath")
                }
                .buttonStyle(HistoryActionButtonStyle())
                .disabled(isAnyRetranscribing)
                .accessibilityLabel("Re-transcribe recording")
            }
        }
    }

    private var actionMenu: some View {
        Menu {
            Button("Copy", action: onCopy)
            Button("Delete", role: .destructive, action: onDelete)
            if audioURL != nil {
                Button(isRetranscribing ? "Re-transcribing…" : "Re-transcribe", action: onRetranscribe)
                    .disabled(isAnyRetranscribing)
            }
        } label: {
            Label("Actions", systemImage: "ellipsis.circle")
        }
        .menuStyle(.button)
        .buttonStyle(HistoryActionButtonStyle())
        .fixedSize()
        .accessibilityLabel("Transcript actions")
    }

    private func actionButton(_ title: String, icon: String, role: ButtonRole? = nil, action: @escaping () -> Void) -> some View {
        Button(role: role, action: action) {
            Label(title, systemImage: icon)
        }
        .buttonStyle(HistoryActionButtonStyle())
    }

    private func playbackSection(_ url: URL) -> some View {
        VStack(spacing: 12) {
            Divider()
            WaveformView(audioURL: url, currentTime: $audioPlayer.currentTime, duration: $audioPlayer.duration)
                .frame(height: 60)
            ViewThatFits(in: .horizontal) {
                HStack {
                    playbackControls(url)
                    Spacer()
                    playbackTime
                }
                VStack(alignment: .leading, spacing: 8) {
                    playbackControls(url)
                    playbackTime
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(HistoryActionButtonStyle())
        }
    }

    @ViewBuilder private func playbackControls(_ url: URL) -> some View {
        Button {
            if audioPlayer.isPlaying { audioPlayer.pause() }
            else { audioPlayer.play() }
        } label: {
            Label(audioPlayer.isPlaying ? "Pause" : "Play Audio", systemImage: audioPlayer.isPlaying ? "pause.fill" : "play.fill")
        }
        .accessibilityLabel(audioPlayer.isPlaying ? "Pause recording" : "Play recording")
        Button { NSWorkspace.shared.activateFileViewerSelecting([url]) } label: {
            Label("Show in Finder", systemImage: "folder")
        }
        .accessibilityLabel("Show recording in Finder")
    }

    private var playbackTime: some View {
        Text("\(timeText(audioPlayer.currentTime)) / \(timeText(audioPlayer.duration))")
            .font(Typography.captionSmall)
            .foregroundStyle(Color.textMuted)
            .monospacedDigit()
    }

}

private func durationText(_ duration: TimeInterval) -> String {
    let seconds = Int(duration)
    return seconds < 60 ? "\(seconds)s" : "\(seconds / 60)m"
}

private func timeText(_ time: TimeInterval) -> String {
    String(format: "%d:%02d", Int(time) / 60, Int(time) % 60)
}
