import SwiftUI

/// Pure selection and search behavior for the spoken-language picker.
///
/// The canonical language catalog remains `GeneralSettingsTab.whisperLanguages`
/// because it is also used by `LanguagePreferences` to name detected languages.
enum SpokenLanguagePickerLogic {
    static let autoCode = "auto"
    static let maximumRecentLanguages = 5

    static func displayName(for code: String) -> String {
        if code == autoCode { return "Auto-detect" }
        return GeneralSettingsTab.whisperLanguages.first(where: { $0.code == code })?.name ?? code
    }

    static func filteredLanguages(matching query: String) -> [(code: String, name: String)] {
        let normalizedQuery = normalize(query)
        if normalizedQuery.isEmpty { return GeneralSettingsTab.whisperLanguages }

        return GeneralSettingsTab.whisperLanguages.filter { language in
            normalize(language.code).contains(normalizedQuery)
                || normalize(language.name).contains(normalizedQuery)
        }
    }

    static func isEmptySearch(_ query: String) -> Bool {
        normalize(query).isEmpty
    }

    static func matchesAutoDetect(query: String) -> Bool {
        let normalizedQuery = normalize(query)
        return normalizedQuery.isEmpty
            || normalize("Auto-detect spoken language").contains(normalizedQuery)
            || autoCode.contains(normalizedQuery)
    }

    static func recentLanguageCodes(from storedValue: String) -> [String] {
        recentLanguageCodes(storedValue.split(separator: ",").map(String.init))
    }

    /// The exact order the picker displays and its arrow keys navigate.
    static func displayedLanguageCodes(
        query: String,
        selectedCode: String,
        recentCodes: [String]
    ) -> [String] {
        if !isEmptySearch(query) {
            var codes = [String]()
            if matchesAutoDetect(query: query) { codes.append(autoCode) }
            codes.append(contentsOf: filteredLanguages(matching: query).map(\.code))
            return codes
        }

        let recents = recentLanguageCodes(recentCodes).filter { $0 != selectedCode }
        var codes = [selectedCode]
        codes.append(contentsOf: recents)
        if selectedCode != autoCode { codes.append(autoCode) }

        let displayedCodes = Set(codes)
        codes.append(
            contentsOf: GeneralSettingsTab.whisperLanguages.map(\.code).filter {
                !displayedCodes.contains($0)
            })
        return codes
    }

    private static func recentLanguageCodes(_ codes: [String]) -> [String] {
        let validCodes = Set(GeneralSettingsTab.whisperLanguages.map(\.code))
        var seen = Set<String>()

        let validUniqueCodes = codes.filter { code in
            if code == autoCode || !validCodes.contains(code) || seen.contains(code) { return false }
            seen.insert(code)
            return true
        }
        return Array(validUniqueCodes.prefix(maximumRecentLanguages))
    }

    static func updatedRecentLanguages(selecting code: String, from storedValue: String) -> String {
        if code == autoCode { return storedValue }

        var codes = recentLanguageCodes(from: storedValue).filter { $0 != code }
        codes.insert(code, at: 0)
        return codes.prefix(maximumRecentLanguages).joined(separator: ",")
    }

    private static func normalize(_ value: String) -> String {
        value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .lowercased()
    }
}

struct SpokenLanguagePicker: View {
    let selectedCode: String
    let recentLanguageCodes: [String]
    let isDisabled: Bool
    let selectLanguage: (String) -> Void

    @State private var isPresented = false

    var body: some View {
        Button {
            isPresented = true
        } label: {
            HStack(spacing: 6) {
                Text(isDisabled ? "English" : SpokenLanguagePickerLogic.displayName(for: selectedCode))
                    .font(Typography.bodySmall)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 9))
            }
            .foregroundStyle(isDisabled ? Color.textMuted : Color.textPrimary)
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(Color.bgHover)
            .clipShape(RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Speech language")
        .accessibilityValue(
            isDisabled
                ? "English, unavailable for this model"
                : SpokenLanguagePickerLogic.displayName(for: selectedCode))
        .accessibilityHint(
            isDisabled
                ? "This English-only model always transcribes in English."
                : "Opens searchable language selection.")
        .disabled(isDisabled)
        .popover(isPresented: $isPresented, arrowEdge: .bottom) {
            SpokenLanguagePickerPopover(
                selectedCode: selectedCode,
                recentLanguageCodes: recentLanguageCodes,
                selectLanguage: { code in
                    selectLanguage(code)
                    isPresented = false
                },
                dismiss: { isPresented = false })
        }
    }
}

private struct SpokenLanguagePickerPopover: View {
    let selectedCode: String
    let recentLanguageCodes: [String]
    let selectLanguage: (String) -> Void
    let dismiss: () -> Void

    @State private var query = ""
    @State private var highlightedCode: String?
    @FocusState private var isSearchFocused: Bool

    private var visibleRecentCodes: [String] {
        SpokenLanguagePickerLogic.recentLanguageCodes(from: recentLanguageCodes.joined(separator: ","))
            .filter { $0 != selectedCode }
    }

    private var displayedLanguageCodes: [String] {
        SpokenLanguagePickerLogic.displayedLanguageCodes(
            query: query,
            selectedCode: selectedCode,
            recentCodes: recentLanguageCodes)
    }

    private var allLanguageCodes: [String] {
        Array(displayedLanguageCodes.dropFirst(1 + visibleRecentCodes.count))
    }

    private var hasSearchQuery: Bool {
        !SpokenLanguagePickerLogic.isEmptySearch(query)
    }

    var body: some View {
        ScrollViewReader { scrollProxy in
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(Color.textMuted)
                        .accessibilityHidden(true)
                    TextField("Search languages", text: $query)
                        .textFieldStyle(.plain)
                        .focused($isSearchFocused)
                        .onKeyPress(.downArrow) { moveHighlight(by: 1) }
                        .onKeyPress(.upArrow) { moveHighlight(by: -1) }
                        .onKeyPress(.return) { selectHighlightedLanguage() }
                        .accessibilityLabel("Search spoken languages")
                    if !query.isEmpty {
                        Button {
                            query = ""
                            highlightedCode = nil
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Clear language search")
                    }
                }
                .padding(10)
                .background(Color.bgHover, in: RoundedRectangle(cornerRadius: 8))

                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        if !hasSearchQuery {
                            Text("Current selection")
                                .font(Typography.captionSmall)
                                .foregroundStyle(Color.textMuted)
                                .padding(.top, 2)
                            languageRow(
                                code: selectedCode,
                                name: SpokenLanguagePickerLogic.displayName(for: selectedCode))

                            if !visibleRecentCodes.isEmpty {
                                sectionTitle("Recent")
                                ForEach(visibleRecentCodes, id: \.self) { code in
                                    languageRow(
                                        code: code,
                                        name: SpokenLanguagePickerLogic.displayName(for: code))
                                }
                            }

                            sectionTitle("All languages")
                            ForEach(allLanguageCodes, id: \.self) { code in
                                languageRow(
                                    code: code,
                                    name: SpokenLanguagePickerLogic.displayName(for: code))
                            }
                        } else if displayedLanguageCodes.isEmpty {
                            Text("No languages match \"\(query)\"")
                                .font(Typography.bodySmall)
                                .foregroundStyle(Color.textMuted)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.vertical, 16)
                                .accessibilityLabel("No languages match \(query)")
                        } else {
                            ForEach(displayedLanguageCodes, id: \.self) { code in
                                languageRow(
                                    code: code,
                                    name: SpokenLanguagePickerLogic.displayName(for: code))
                            }
                        }
                    }
                }
                .onChange(of: highlightedCode) { _, code in
                    if let code {
                        withAnimation { scrollProxy.scrollTo(code, anchor: .center) }
                    }
                }
                .frame(width: 300, height: 310)
            }
            .padding(12)
            .onAppear {
                DispatchQueue.main.async {
                    isSearchFocused = true
                    highlightedCode = selectedCode
                    scrollProxy.scrollTo(selectedCode, anchor: .center)
                }
            }
            .onChange(of: query) { _, _ in
                highlightedCode = nil
            }
            .onExitCommand(perform: dismiss)
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Spoken language selection")
        }
    }

    private func sectionTitle(_ title: String) -> some View {
        Text(title)
            .font(Typography.captionSmall)
            .foregroundStyle(Color.textMuted)
            .padding(.top, 10)
    }

    private func languageRow(code: String, name: String) -> some View {
        Button {
            selectLanguage(code)
        } label: {
            HStack(spacing: 8) {
                Text(name)
                    .font(Typography.bodySmall)
                Spacer()
                if code == selectedCode {
                    Image(systemName: "checkmark")
                        .font(.system(size: 11, weight: .semibold))
                        .accessibilityHidden(true)
                }
            }
            .foregroundStyle(Color.textPrimary)
            .padding(.horizontal, 8)
            .padding(.vertical, 7)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(highlightedCode == code ? Color.bgHover : Color.clear)
            .clipShape(RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Select \(name)")
        .accessibilityValue(code == selectedCode ? "Selected" : "")
        .id(code)
    }

    private func moveHighlight(by offset: Int) -> KeyPress.Result {
        if displayedLanguageCodes.isEmpty { return .handled }

        let currentIndex = highlightedCode.flatMap { displayedLanguageCodes.firstIndex(of: $0) } ?? -1
        let nextIndex = min(max(currentIndex + offset, 0), displayedLanguageCodes.count - 1)
        highlightedCode = displayedLanguageCodes[nextIndex]
        return .handled
    }

    private func selectHighlightedLanguage() -> KeyPress.Result {
        if let highlightedCode, displayedLanguageCodes.contains(highlightedCode) {
            selectLanguage(highlightedCode)
            return .handled
        }
        return .ignored
    }
}
