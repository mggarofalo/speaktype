import Foundation

/// A durable, replayable history change. The operation ID is independent from
/// any transcript ID so the store can distinguish a retry from a later edit of
/// the same transcript.
nonisolated struct HistoryMutation: Identifiable, Codable, Sendable {
    nonisolated struct TranscriptUpdate: Codable, Sendable {
        let id: UUID
        let transcript: String
        let modelUsed: String?
        let transcriptionTime: TimeInterval?
    }

    nonisolated struct TranscriptDeletion: Codable, Sendable {
        let id: UUID
        let deleteAudioFile: Bool
    }

    nonisolated enum Operation: Codable, Sendable {
        case add(HistoryItem)
        case update(TranscriptUpdate)
        case delete(TranscriptDeletion)
        case clear

        private enum CodingKeys: String, CodingKey {
            case kind
            case item
            case update
            case deletion
        }

        private enum Kind: String, Codable {
            case add
            case update
            case delete
            case clear
        }

        init(from decoder: Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            switch try values.decode(Kind.self, forKey: .kind) {
            case .add:
                self = .add(try values.decode(HistoryItem.self, forKey: .item))
            case .update:
                self = .update(try values.decode(TranscriptUpdate.self, forKey: .update))
            case .delete:
                self = .delete(try values.decode(TranscriptDeletion.self, forKey: .deletion))
            case .clear:
                self = .clear
            }
        }

        func encode(to encoder: Encoder) throws {
            var values = encoder.container(keyedBy: CodingKeys.self)
            switch self {
            case .add(let item):
                try values.encode(Kind.add, forKey: .kind)
                try values.encode(item, forKey: .item)
            case .update(let update):
                try values.encode(Kind.update, forKey: .kind)
                try values.encode(update, forKey: .update)
            case .delete(let deletion):
                try values.encode(Kind.delete, forKey: .kind)
                try values.encode(deletion, forKey: .deletion)
            case .clear:
                try values.encode(Kind.clear, forKey: .kind)
            }
        }
    }

    let id: UUID
    let operation: Operation

    init(id: UUID = UUID(), operation: Operation) {
        self.id = id
        self.operation = operation
    }
}

nonisolated struct HistoryRecoveryFaults: Sendable {
    /// Test seam for a process interruption after SQLite commits but before the
    /// journal removes the operation. Normal application code leaves this nil.
    let afterApplyingMutation: (@Sendable (HistoryMutation) async throws -> Void)?

    init(afterApplyingMutation: (@Sendable (HistoryMutation) async throws -> Void)? = nil) {
        self.afterApplyingMutation = afterApplyingMutation
    }
}

nonisolated enum HistoryRecoveryError: LocalizedError, Sendable {
    case journalUnavailable(String)
    case journalInUse
    case pendingMutations(count: Int, message: String?)

    var errorDescription: String? {
        switch self {
        case .journalUnavailable(let message):
            return "History recovery journal: \(message)"
        case .journalInUse:
            return "History saving is active in another copy of SpeakType. Close it, then retry saves."
        case .pendingMutations(let count, let message):
            let noun = count == 1 ? "change" : "changes"
            if let message, !message.isEmpty {
                return "\(count) history \(noun) could not be saved. \(message)"
            }
            return "\(count) history \(noun) could not be saved."
        }
    }
}
