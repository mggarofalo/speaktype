import AVFoundation
import KeyboardShortcuts
import SwiftUI

struct SettingsView: View {
    @AppStorage("selectedSettingsTab") private var selectedTab: SettingsTab = .general

    var body: some View {
        VStack(spacing: 0) {
            // Header with tabs
            VStack(alignment: .leading, spacing: 16) {
                Text("Settings")
                    .font(Typography.displayLarge)
                    .foregroundStyle(Color.textPrimary)

                // Tab bar
                HStack(spacing: 0) {
                    ForEach(SettingsTab.allCases) { tab in
                        SettingsTabButton(
                            tab: tab,
                            isSelected: selectedTab == tab,
                            action: { selectedTab = tab }
                        )
                    }
                    Spacer()
                }
            }
            .padding(.horizontal, 24)
            .padding(.top, 24)
            .padding(.bottom, 16)

            // Tab content
            switch selectedTab {
            case .general:
                GeneralSettingsTab()
            case .transcription:
                GeneralSettingsTab(transcriptionOnly: true)
            case .audio:
                AudioSettingsTab()
            case .permissions:
                PermissionsSettingsTab()
            }
        }
        .background(Color.clear)
    }
}

enum SettingsTab: String, CaseIterable, Identifiable {
    case general = "General"
    case transcription = "Transcription"
    case audio = "Audio"
    case permissions = "Permissions"

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .general: return "gearshape"
        case .transcription: return "waveform"
        case .audio: return "mic"
        case .permissions: return "shield"
        }
    }
}

struct SettingsTabButton: View {
    let tab: SettingsTab
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: tab.icon)
                    .font(.system(size: 13))
                Text(tab.rawValue)
                    .font(Typography.bodyMedium)
            }
            .foregroundStyle(isSelected ? Color.textPrimary : Color.textMuted)
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(isSelected ? Color.bgHover : Color.clear)
            .clipShape(RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
    }
}

// MARK: - General Settings Tab

struct GeneralSettingsTab: View {
    var transcriptionOnly = false
    @State private var engineStatus: String?
    @State private var isSwitchingEngine = false
    @AppStorage("appTheme") private var appTheme: AppTheme = .system
    // Default false to match AppDelegate's UserDefaults read — private by default,
    // no network traffic until the user explicitly opts in to update checks.
    @AppStorage("autoUpdate") private var autoUpdate = false
    @AppStorage("selectedHotkey") private var selectedHotkey: HotkeyOption = .fn
    @AppStorage("recordingMode") private var recordingMode: Int = 0  // 0: Hold to record, 1: Toggle
    @AppStorage("launchAtLogin") private var launchAtLogin: Bool = false
    @AppStorage("showMenuBarIcon") private var showMenuBarIcon: Bool = true
    @AppStorage("hideDockIcon") private var hideDockIcon: Bool = false
    @AppStorage("removeFillerWords") private var removeFillerWords: Bool = false
    @AppStorage("pauseMediaDuringRecording") private var pauseMediaDuringRecording: Bool = false
    @AppStorage("customVocabulary") private var customVocabulary: String = VocabularyDefaults.seed
    @AppStorage("transcriptionLanguage") private var transcriptionLanguage: String = "auto"
    @AppStorage("recentTranscriptionLanguages") private var recentLanguagesString: String = ""
    @AppStorage("transcriptionEngine") private var transcriptionEngine: String =
        TranscriptionEngineSelection.defaultKind.rawValue
    @AppStorage("selectedModelVariant") private var selectedModelVariant: String = ""
    @AppStorage(WhisperCppTuning.Key.entropyThreshold) private var entropyThreshold: Double =
        WhisperCppTuning.defaultEntropyThreshold
    @AppStorage(WhisperCppTuning.Key.temperatureIncrement) private var temperatureIncrement: Double =
        WhisperCppTuning.defaultTemperatureIncrement
    @AppStorage(WhisperCppTuning.Key.carryContext) private var carryContext: Bool =
        WhisperCppTuning.defaultCarryContext

    private var recentLanguageCodes: [String] {
        SpokenLanguagePickerLogic.recentLanguageCodes(from: recentLanguagesString)
    }

    private func updateRecentLanguages(code: String) {
        recentLanguagesString = SpokenLanguagePickerLogic.updatedRecentLanguages(
            selecting: code, from: recentLanguagesString)
    }

    // MARK: - Model-aware language selection

    private var selectedModelIsEnglishOnly: Bool {
        LanguagePreferences.isEnglishOnly(selectedModelVariant)
    }

    private var selectedModelDisplayName: String {
        AIModel.model(for: selectedModelVariant)?.name ?? "This model"
    }

    /// The selection for the *current* model, falling back to the global one.
    /// Reads `transcriptionLanguage` so the view re-renders when it changes —
    /// `setLanguage` always mirrors to that key.
    private var effectiveLanguage: String {
        _ = transcriptionLanguage
        return LanguagePreferences.storedLanguage(forModel: selectedModelVariant)
    }

    private func setLanguage(_ code: String) {
        LanguagePreferences.setLanguage(code, forModel: selectedModelVariant)
        updateRecentLanguages(code: code)
    }

    // MARK: - Decoding parameters (whisper.cpp)

    @ViewBuilder
    private var decodingSection: some View {
        SettingsSection {
            SettingsSectionHeader(
                icon: "slider.horizontal.3", title: "Decoding",
                subtitle: "whisper.cpp accuracy trade-offs")

            settingsStepper(
                title: "Entropy threshold",
                value: $entropyThreshold, range: 0.5...6.0, step: 0.1, format: "%.1f")

            Text(
                "Guards against repetition loops: a segment whose tokens look degenerate is re-decoded at a higher temperature instead of being emitted. Raising it catches more loops; above about 4 it starts discarding valid speech."
            )
            .font(Typography.captionSmall)
            .foregroundStyle(Color.textMuted)
            .padding(.top, 4)

            settingsStepper(
                title: "Temperature increment",
                value: $temperatureIncrement, range: 0.0...1.0, step: 0.05, format: "%.2f")

            Text(
                "How much hotter each retry decodes. 0 disables the retry entirely, so a looping segment is emitted as-is."
            )
            .font(Typography.captionSmall)
            .foregroundStyle(Color.textMuted)
            .padding(.top, 4)

            Toggle(isOn: $carryContext) {
                Text("Carry context between dictations")
                    .font(Typography.bodyMedium)
                    .foregroundStyle(Color.textPrimary)
            }
            .toggleStyle(.switch)
            .padding(.top, 6)

            Text(
                "Off is recommended. On, each dictation is prompted with the previous one's text, which can bleed the end of one transcript into the start of the next. It does not affect coherence within a single dictation."
            )
            .font(Typography.captionSmall)
            .foregroundStyle(Color.textMuted)
            .padding(.top, 4)

            if !WhisperCppTuning.isDefault {
                Button("Reset to validated defaults") {
                    WhisperCppTuning.resetToDefaults()
                    entropyThreshold = WhisperCppTuning.defaultEntropyThreshold
                    temperatureIncrement = WhisperCppTuning.defaultTemperatureIncrement
                    carryContext = WhisperCppTuning.defaultCarryContext
                }
                .font(Typography.captionSmall)
                .padding(.top, 6)
            }
        }
    }

    @ViewBuilder
    private func settingsStepper(
        title: String, value: Binding<Double>, range: ClosedRange<Double>, step: Double,
        format: String
    ) -> some View {
        HStack {
            Text(title)
                .font(Typography.bodyMedium)
                .foregroundStyle(Color.textPrimary)
            Spacer()
            Text(String(format: format, value.wrappedValue))
                .font(Typography.bodySmall.monospacedDigit())
                .foregroundStyle(Color.textPrimary)
                .frame(minWidth: 40, alignment: .trailing)
            Stepper(title, value: value, in: range, step: step)
                .labelsHidden()
        }
        .padding(.top, 6)
    }

    @StateObject private var updateService = UpdateService.shared

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                if !transcriptionOnly {
                    // Appearance
                    SettingsSection {
                        SettingsSectionHeader(
                            icon: "paintpalette", title: "Appearance",
                            subtitle: "Choose your preferred theme")

                        HStack(spacing: 20) {
                            ForEach(AppTheme.allCases) { theme in
                                RadioButton(
                                    title: theme.rawValue,
                                    isSelected: appTheme == theme,
                                    action: { appTheme = theme }
                                )
                            }
                        }
                    }

                    // Shortcuts
                    SettingsSection {
                        SettingsSectionHeader(
                            icon: "command", title: "Shortcuts", subtitle: "Configure recording hotkeys"
                        )

                        VStack(spacing: 16) {
                            HStack {
                                Text("Primary Hotkey")
                                    .font(Typography.bodyMedium)
                                    .foregroundStyle(Color.textPrimary)
                                Spacer()
                                Menu {
                                    ForEach(HotkeyOption.allCases) { option in
                                        Button(option.displayName) {
                                            selectedHotkey = option
                                            AppDelegate.syncChordHotkeyEnabled()
                                        }
                                    }
                                } label: {
                                    HStack(spacing: 6) {
                                        Text(selectedHotkey.displayName)
                                            .font(Typography.bodySmall)
                                            .foregroundStyle(Color.textPrimary)
                                        Image(systemName: "chevron.up.chevron.down")
                                            .font(.system(size: 9))
                                            .foregroundStyle(Color.textPrimary)
                                    }
                                    .padding(.horizontal, 12)
                                    .padding(.vertical, 7)
                                    .background(Color.bgHover)
                                    .clipShape(RoundedRectangle(cornerRadius: 6))
                                }
                                .menuStyle(.borderlessButton)
                            }

                            if selectedHotkey == .chord {
                                HStack {
                                    Text("Chord")
                                        .font(Typography.bodyMedium)
                                        .foregroundStyle(Color.textPrimary)
                                    Spacer()
                                    KeyboardShortcuts.Recorder("", name: .dictationChord)
                                }
                            }

                            VStack(alignment: .leading, spacing: 6) {
                                HStack {
                                    Text("Recording Mode")
                                        .font(Typography.bodyMedium)
                                        .foregroundStyle(Color.textPrimary)
                                    Spacer()
                                    Picker("", selection: $recordingMode) {
                                        Text("Hold to record").tag(0)
                                        Text("Toggle").tag(1)
                                    }
                                    .pickerStyle(.segmented)
                                    .frame(width: 180)
                                }

                                Text(
                                    recordingMode == 0
                                        ? "Hold the hotkey down to record, release when done."
                                        : "Press the hotkey to start recording, press again to stop."
                                )
                                .font(Typography.captionSmall)
                                .foregroundStyle(Color.textMuted)
                                .padding(.top, 2)
                            }

                        }
                    }

                    // General Behavior
                    SettingsSection {
                        SettingsSectionHeader(
                            icon: "macwindow", title: "General", subtitle: "App behavior settings"
                        )

                        VStack(spacing: 16) {
                            HStack {
                                Text("Launch on startup")
                                    .font(Typography.bodyMedium)
                                    .foregroundStyle(Color.textPrimary)
                                Spacer()
                                Toggle("", isOn: $launchAtLogin)
                                    .labelsHidden()
                                    .onChange(of: launchAtLogin) {
                                        AppDelegate.applyLaunchAtLoginPolicy()
                                    }
                            }

                            HStack {
                                Text("Show menu bar icon")
                                    .font(Typography.bodyMedium)
                                    .foregroundStyle(Color.textPrimary)
                                Spacer()
                                Toggle("", isOn: $showMenuBarIcon)
                                    .labelsHidden()
                                    .disabled(hideDockIcon)  // Must stay reachable somehow
                            }

                            VStack(alignment: .leading, spacing: 6) {
                                HStack {
                                    Text("Hide Dock icon")
                                        .font(Typography.bodyMedium)
                                        .foregroundStyle(Color.textPrimary)
                                    Spacer()
                                    Toggle("", isOn: $hideDockIcon)
                                        .labelsHidden()
                                        .onChange(of: hideDockIcon) {
                                            if hideDockIcon { showMenuBarIcon = true }
                                            AppDelegate.applyDockIconPolicy()
                                        }
                                }

                                if hideDockIcon {
                                    Text("The menu bar icon stays on so you can reach the app.")
                                        .font(Typography.captionSmall)
                                        .foregroundStyle(Color.textMuted)
                                }
                            }

                            VStack(alignment: .leading, spacing: 6) {
                                HStack {
                                    Text("Remove filler words")
                                        .font(Typography.bodyMedium)
                                        .foregroundStyle(Color.textPrimary)
                                    Spacer()
                                    Toggle("", isOn: $removeFillerWords)
                                        .labelsHidden()
                                }

                                Text("Strips \"um\", \"uh\", \"erm\", and \"hmm\" from transcriptions.")
                                    .font(Typography.captionSmall)
                                    .foregroundStyle(Color.textMuted)
                            }

                            VStack(alignment: .leading, spacing: 6) {
                                HStack {
                                    Text("Pause media while recording")
                                        .font(Typography.bodyMedium)
                                        .foregroundStyle(Color.textPrimary)
                                    Spacer()
                                    Toggle("", isOn: $pauseMediaDuringRecording)
                                        .labelsHidden()
                                }

                                Text("Pauses Music or Spotify when dictation starts and resumes after.")
                                    .font(Typography.captionSmall)
                                    .foregroundStyle(Color.textMuted)
                            }
                        }
                    }

                }

                if transcriptionOnly {
                    SettingsSection {
                        SettingsSectionHeader(
                            icon: "cpu", title: "Transcription engine", subtitle: "Choose how speech is processed"
                        )
                        VStack(alignment: .leading, spacing: 6) {
                            HStack {
                                Text("Transcription engine")
                                    .font(Typography.bodyMedium)
                                    .foregroundStyle(Color.textPrimary)
                                Spacer()
                                Picker("", selection: $transcriptionEngine) {
                                    Text("whisper.cpp").tag(TranscriptionEngineKind.whispercpp.rawValue)
                                    Text("WhisperKit").tag(TranscriptionEngineKind.whisperkit.rawValue)
                                }
                                .pickerStyle(.segmented)
                                .frame(width: 200)
                                .disabled(isSwitchingEngine || WhisperService.shared.isLoading)
                                .onChange(of: transcriptionEngine) {
                                    switchEngine()
                                }
                            }

                            Text(
                                "whisper.cpp (Metal) is much faster on Apple Silicon. Each engine uses its own downloaded models."
                            )
                            .font(Typography.captionSmall)
                            .foregroundStyle(Color.textMuted)
                            .padding(.top, 2)
                        }
                        if let engineStatus {
                            Text(engineStatus)
                                .font(Typography.bodySmall)
                                .foregroundStyle(Color.textSecondary)
                                .accessibilityLabel(engineStatus)
                        }
                    }

                    // Spoken Language
                    SettingsSection {
                        SettingsSectionHeader(
                            icon: "globe", title: "Spoken Language",
                            subtitle: "Hint for the language you are speaking")

                        HStack {
                            Text("Speech language")
                                .font(Typography.bodyMedium)
                                .foregroundStyle(
                                    selectedModelIsEnglishOnly ? Color.textMuted : Color.textPrimary)
                            Spacer()
                            SpokenLanguagePicker(
                                selectedCode: effectiveLanguage,
                                recentLanguageCodes: recentLanguageCodes,
                                isDisabled: selectedModelIsEnglishOnly,
                                selectLanguage: setLanguage)
                        }

                        // The control is inert on a .en model — whisper.cpp emits
                        // English from those whatever language is requested — so say
                        // that instead of letting the setting silently do nothing.
                        if selectedModelIsEnglishOnly {
                            Text(
                                "\(selectedModelDisplayName) is English-only, so it ignores this setting. Choose a multilingual model to dictate in another language."
                            )
                            .font(Typography.captionSmall)
                            .foregroundStyle(Color.textMuted)
                            .padding(.top, 4)
                        } else {
                            Text("Saved per model — each model remembers its own language.")
                                .font(Typography.captionSmall)
                                .foregroundStyle(Color.textMuted)
                                .padding(.top, 4)

                            Text(
                                "This is a hint for transcription. It does not choose an output language and it does not translate the result."
                            )
                            .font(Typography.captionSmall)
                            .foregroundStyle(Color.textMuted)
                            .padding(.top, 4)

                            Text(
                                "If this does not match the language you actually speak, the result can be inaccurate or even come back in the wrong language. Auto-detect is the safest default."
                            )
                            .font(Typography.captionSmall)
                            .foregroundStyle(Color.textMuted)
                            .padding(.top, 4)

                            Text("Accuracy for languages like Hindi depends heavily on the model you selected.")
                                .font(Typography.captionSmall)
                                .foregroundStyle(Color.textMuted)
                                .padding(.top, 4)
                        }
                    }

                    // Decoding (whisper.cpp only)
                    if transcriptionEngine == TranscriptionEngineKind.whispercpp.rawValue {
                        decodingSection
                    }

                    // Custom Vocabulary
                    SettingsSection {
                        SettingsSectionHeader(
                            icon: "text.book.closed", title: "Custom Vocabulary",
                            subtitle: "Names and terms the transcriber should know")

                        VStack(alignment: .leading, spacing: 8) {
                            TextEditor(text: $customVocabulary)
                                .font(Typography.bodySmall)
                                .foregroundStyle(Color.textPrimary)
                                .scrollContentBackground(.hidden)
                                .padding(8)
                                .frame(minHeight: 90, maxHeight: 140)
                                .background(Color.bgHover)
                                .clipShape(RoundedRectangle(cornerRadius: 8))

                            Text(
                                "Comma- or newline-separated. Biases transcription toward these spellings — useful for product names, coworkers, and jargon. Applies to the next dictation; leave empty to disable."
                            )
                            .font(Typography.captionSmall)
                            .foregroundStyle(Color.textMuted)
                        }
                    }

                }

                if !transcriptionOnly {
                    // Updates
                    SettingsSection {
                        SettingsSectionHeader(
                            icon: "arrow.down.circle", title: "Updates",
                            subtitle: "SpeakType \(AppVersion.currentVersion)")

                        VStack(spacing: 16) {
                            HStack {
                                Text("Automatically check for updates")
                                    .font(Typography.bodyMedium)
                                    .foregroundStyle(Color.textPrimary)
                                Spacer()
                                Toggle("", isOn: $autoUpdate)
                                    .labelsHidden()
                            }

                            Button(action: {
                                Task {
                                    await updateService.checkForUpdates()
                                }
                            }) {
                                HStack(spacing: 6) {
                                    if updateService.isCheckingForUpdates {
                                        ProgressView()
                                            .scaleEffect(0.7)
                                            .frame(width: 14, height: 14)
                                    } else {
                                        Image(systemName: "arrow.clockwise")
                                            .font(.system(size: 12))
                                    }
                                    Text(
                                        updateService.isCheckingForUpdates
                                            ? "Checking..." : "Check for Updates"
                                    )
                                    .font(Typography.labelMedium)
                                }
                                .foregroundStyle(Color.textPrimary)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 8)
                                .background(Color.bgHover)
                                .clipShape(RoundedRectangle(cornerRadius: 8))
                            }
                            .buttonStyle(.plain)
                            .disabled(updateService.isCheckingForUpdates)
                            if let status = updateService.checkStatus {
                                Text(status.message)
                                    .font(Typography.bodySmall)
                                    .foregroundStyle(status.isError ? Color.accentError : Color.textSecondary)
                                    .accessibilityLabel(status.message)
                            }
                            Text("Update checks look for published versions. Installation is manual.")
                                .font(Typography.captionSmall)
                                .foregroundStyle(Color.textMuted)
                        }
                    }
                }

            }
            .padding(24)
        }
    }

    private func switchEngine() {
        isSwitchingEngine = true
        engineStatus = "Checking downloaded models…"
        Task {
            await ModelManager.shared.refreshDownloadedModels()
            guard !selectedModelVariant.isEmpty,
                ModelManager.shared.isDownloaded(variant: selectedModelVariant)
            else {
                engineStatus =
                    "Choose a downloaded model for this engine in AI Models. Each engine keeps its own models."
                isSwitchingEngine = false
                return
            }
            do {
                try await WhisperService.shared.loadModel(variant: selectedModelVariant)
                engineStatus = "Ready to transcribe with this engine."
            } catch {
                engineStatus = "Unable to load this model: \(error.localizedDescription)"
            }
            isSwitchingEngine = false
        }
    }

    // All languages supported by Whisper, sorted alphabetically
    static let whisperLanguages: [(code: String, name: String)] = [
        ("af", "Afrikaans"), ("sq", "Albanian"), ("am", "Amharic"), ("ar", "Arabic"),
        ("hy", "Armenian"), ("as", "Assamese"), ("az", "Azerbaijani"), ("ba", "Bashkir"),
        ("eu", "Basque"), ("be", "Belarusian"), ("bn", "Bengali"), ("bs", "Bosnian"),
        ("br", "Breton"), ("bg", "Bulgarian"), ("yue", "Cantonese"), ("ca", "Catalan"),
        ("zh", "Chinese"), ("hr", "Croatian"), ("cs", "Czech"), ("da", "Danish"),
        ("nl", "Dutch"), ("en", "English"), ("et", "Estonian"), ("fo", "Faroese"),
        ("fi", "Finnish"), ("fr", "French"), ("gl", "Galician"), ("ka", "Georgian"),
        ("de", "German"), ("el", "Greek"), ("gu", "Gujarati"), ("ht", "Haitian Creole"),
        ("ha", "Hausa"), ("haw", "Hawaiian"), ("he", "Hebrew"), ("hi", "Hindi"),
        ("hu", "Hungarian"), ("is", "Icelandic"), ("id", "Indonesian"), ("it", "Italian"),
        ("ja", "Japanese"), ("jw", "Javanese"), ("kn", "Kannada"), ("kk", "Kazakh"),
        ("km", "Khmer"), ("ko", "Korean"), ("lo", "Lao"), ("la", "Latin"),
        ("lv", "Latvian"), ("ln", "Lingala"), ("lt", "Lithuanian"), ("lb", "Luxembourgish"),
        ("mk", "Macedonian"), ("mg", "Malagasy"), ("ms", "Malay"), ("ml", "Malayalam"),
        ("mt", "Maltese"), ("mi", "Maori"), ("mr", "Marathi"), ("mn", "Mongolian"),
        ("my", "Myanmar"), ("ne", "Nepali"), ("no", "Norwegian"), ("nn", "Nynorsk"),
        ("oc", "Occitan"), ("ps", "Pashto"), ("fa", "Persian"), ("pl", "Polish"),
        ("pt", "Portuguese"), ("pa", "Punjabi"), ("ro", "Romanian"), ("ru", "Russian"),
        ("sa", "Sanskrit"), ("sr", "Serbian"), ("sn", "Shona"), ("sd", "Sindhi"),
        ("si", "Sinhala"), ("sk", "Slovak"), ("sl", "Slovenian"), ("so", "Somali"),
        ("es", "Spanish"), ("su", "Sundanese"), ("sw", "Swahili"), ("sv", "Swedish"),
        ("tl", "Tagalog"), ("tg", "Tajik"), ("ta", "Tamil"), ("tt", "Tatar"),
        ("te", "Telugu"), ("th", "Thai"), ("bo", "Tibetan"), ("tr", "Turkish"),
        ("tk", "Turkmen"), ("uk", "Ukrainian"), ("ur", "Urdu"), ("uz", "Uzbek"),
        ("vi", "Vietnamese"), ("cy", "Welsh"), ("yi", "Yiddish"), ("yo", "Yoruba"),
    ]
}

// MARK: - Audio Settings Tab

struct AudioSettingsTab: View {
    @StateObject private var audioRecorder = AudioRecordingService.shared

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                SettingsSection {
                    SettingsSectionHeader(
                        icon: "mic", title: "Input Device", subtitle: "Select your microphone")

                    VStack(spacing: 12) {
                        if audioRecorder.availableDevices.isEmpty {
                            Text("No input devices found")
                                .font(Typography.bodyMedium)
                                .foregroundStyle(Color.textMuted)
                                .padding(.vertical, 20)
                        } else {
                            ForEach(audioRecorder.availableDevices, id: \.uniqueID) { device in
                                DeviceRow(
                                    name: device.localizedName,
                                    isActive: audioRecorder.selectedDeviceId == device.uniqueID,
                                    isSelected: audioRecorder.selectedDeviceId == device.uniqueID
                                )
                                .onTapGesture {
                                    audioRecorder.selectedDeviceId = device.uniqueID
                                }
                            }
                        }
                    }

                    Button(action: { audioRecorder.fetchAvailableDevices() }) {
                        HStack(spacing: 6) {
                            Image(systemName: "arrow.clockwise")
                                .font(.system(size: 12))
                            Text("Refresh Devices")
                                .font(Typography.labelMedium)
                        }
                        .foregroundStyle(Color.textPrimary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                        .background(Color.bgHover)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                    }
                    .buttonStyle(.plain)
                    .padding(.top, 8)
                }
            }
            .padding(24)
        }
        .onAppear {
            audioRecorder.fetchAvailableDevices()
        }
    }
}

// MARK: - Permissions Settings Tab

struct PermissionsSettingsTab: View {
    @State private var micStatus: AVAuthorizationStatus = .notDetermined
    @State private var accessibilityStatus: Bool = false
    @State private var timer: Timer?

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                SettingsSection {
                    SettingsSectionHeader(
                        icon: "shield", title: "App Permissions",
                        subtitle: "Required for full functionality")

                    VStack(spacing: 10) {
                        SettingsPermissionItem(
                            icon: "mic.fill",
                            color: Color.textSecondary,
                            title: "Microphone Access",
                            desc: "Record your voice for transcription",
                            isGranted: micStatus == .authorized,
                            action: { openSettings(for: "Privacy_Microphone") }
                        )

                        SettingsPermissionItem(
                            icon: "hand.raised.fill",
                            color: Color.textSecondary,
                            title: "Accessibility Access",
                            desc: "Paste transcribed text directly",
                            isGranted: accessibilityStatus,
                            action: {
                                ClipboardService.shared.requestAccessibilityPermission()
                                // System dialog handles opening Settings when user clicks "Open System Settings"
                            }
                        )
                    }
                }
            }
            .padding(24)
        }
        .onAppear {
            checkPermissions()
            startPolling()
        }
        .onDisappear {
            timer?.invalidate()
        }
    }

    private func startPolling() {
        timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { _ in
            checkPermissions()
        }
    }

    private func checkPermissions() {
        micStatus = AVCaptureDevice.authorizationStatus(for: .audio)
        accessibilityStatus = AXIsProcessTrusted()
    }

    private func openSettings(for pane: String) {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)") {
            NSWorkspace.shared.open(url)
        }
    }
}

// MARK: - Supporting Components

struct SettingsSectionHeader: View {
    let icon: String
    let title: String
    let subtitle: String

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 14))
                .foregroundStyle(Color.textMuted)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(Typography.labelLarge)
                    .foregroundStyle(Color.textPrimary)
                Text(subtitle)
                    .font(Typography.captionSmall)
                    .foregroundStyle(Color.textMuted)
            }

            Spacer()
        }
        .padding(.bottom, 16)
    }
}

struct SettingsSection<Content: View>: View {
    let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            content
        }
        .themedCard(padding: 24)
    }
}

struct ToggleRow: View {
    let title: String
    @Binding var isOn: Bool

    var body: some View {
        HStack {
            Text(title)
                .font(Typography.bodyMedium)
                .foregroundStyle(Color.textPrimary)
            Spacer()
            Toggle("", isOn: $isOn)
                .labelsHidden()
        }
    }
}

struct RadioButton: View {
    let title: String
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                ZStack {
                    Circle()
                        .strokeBorder(
                            isSelected ? Color.accentPrimary : Color.textMuted, lineWidth: 1.5
                        )
                        .frame(width: 18, height: 18)

                    if isSelected {
                        Circle()
                            .fill(Color.accentPrimary)
                            .frame(width: 10, height: 10)
                    }
                }

                Text(title)
                    .font(Typography.bodyMedium)
                    .foregroundStyle(Color.textPrimary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

struct SettingsPermissionItem: View {
    let icon: String
    let color: Color
    let title: String
    let desc: String
    let isGranted: Bool
    let action: () -> Void

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: icon)
                .foregroundStyle(Color.textMuted)
                .font(.system(size: 16))
                .frame(width: 32, height: 32)
                .background(Color.bgHover)
                .clipShape(Circle())

            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(Typography.bodyMedium)
                    .foregroundStyle(Color.textPrimary)
                Text(desc)
                    .font(Typography.captionSmall)
                    .foregroundStyle(Color.textMuted)
            }

            Spacer()

            if isGranted {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(Color.textSecondary)
                    .font(.system(size: 20))
            } else {
                Button("Enable") {
                    action()
                }
                .font(Typography.labelSmall)
                .foregroundStyle(Color.textPrimary)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(Color.bgHover)
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .buttonStyle(.plain)
            }
        }
        .padding(16)
        .background(Color.bgCard)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(Color.border.opacity(0.5), lineWidth: 1)
        )
    }
}

enum AppTheme: String, CaseIterable, Identifiable {
    case light = "Light"
    case dark = "Dark"
    case system = "System"

    var id: String { rawValue }
}
