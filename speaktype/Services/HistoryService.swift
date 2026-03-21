import Foundation
import Combine
import SwiftUI // For IndexSet operations if needed, though Foundation usually covers it, but error says missing import.

struct HistoryItem: Identifiable, Codable, Hashable {
    let id: UUID
    let date: Date
    let transcript: String
    let duration: TimeInterval
    let audioFileURL: URL?
    let modelUsed: String?
    let transcriptionTime: TimeInterval?
    
    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
    
    static func == (lhs: HistoryItem, rhs: HistoryItem) -> Bool {
        lhs.id == rhs.id
    }
}

class HistoryService: ObservableObject {
    static let shared = HistoryService()
    
    @Published var items: [HistoryItem] = []
    
    private let saveKey = "history_items"
    
    private init() {
        loadHistory()
    }
    
    func addItem(transcript: String, duration: TimeInterval, audioFileURL: URL? = nil, modelUsed: String? = nil, transcriptionTime: TimeInterval? = nil) {
        let normalizedTranscript = WhisperService.normalizedTranscription(from: transcript)
        guard !normalizedTranscript.isEmpty else { return }

        let newItem = HistoryItem(
            id: UUID(),
            date: Date(),
            transcript: normalizedTranscript,
            duration: duration,
            audioFileURL: audioFileURL,
            modelUsed: modelUsed,
            transcriptionTime: transcriptionTime
        )
        items.insert(newItem, at: 0) // Newest first
        saveHistory()
    }
    
    func deleteItem(at offsets: IndexSet) {
        items.remove(atOffsets: offsets)
        saveHistory()
    }
    
    func deleteItem(id: UUID) {
        items.removeAll { $0.id == id }
        saveHistory()
    }
    
    func clearAll() {
        items.removeAll()
        saveHistory()
    }
    
    private func saveHistory() {
        if let encoded = try? JSONEncoder().encode(items) {
            UserDefaults.standard.set(encoded, forKey: saveKey)
        }
    }
    
    private func loadHistory() {
        if let data = UserDefaults.standard.data(forKey: saveKey),
           let decoded = try? JSONDecoder().decode([HistoryItem].self, from: data) {
            let normalizedItems = decoded.compactMap { item -> HistoryItem? in
                let normalizedTranscript = WhisperService.normalizedTranscription(
                    from: item.transcript)
                guard !normalizedTranscript.isEmpty else { return nil }

                guard normalizedTranscript != item.transcript else { return item }

                return HistoryItem(
                    id: item.id,
                    date: item.date,
                    transcript: normalizedTranscript,
                    duration: item.duration,
                    audioFileURL: item.audioFileURL,
                    modelUsed: item.modelUsed,
                    transcriptionTime: item.transcriptionTime
                )
            }

            items = normalizedItems

            if normalizedItems.count != decoded.count
                || zip(decoded, normalizedItems).contains(where: { $0.transcript != $1.transcript })
            {
                saveHistory()
            }
        }
    }
}
