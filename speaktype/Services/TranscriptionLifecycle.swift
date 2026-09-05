import Foundation

extension Notification.Name {
    static let finishRecordingForTermination = Notification.Name("finishRecordingForTermination")
}

/// Tracks the complete operation, including the caller's work after decoding:
/// metadata collection and enqueueing the durable history write.
@MainActor
final class TranscriptionLifecycle {
    static let shared = TranscriptionLifecycle()

    private(set) var isTerminating = false
    private var activeOperations: Set<UUID> = []
    private var idleWaiters: [CheckedContinuation<Void, Never>] = []

    /// Register synchronously, before scheduling the task. Otherwise a quit event
    /// could see an empty registry while an accepted transcription is queued.
    @discardableResult
    func perform(_ operation: @escaping @MainActor () async -> Void) -> Task<Void, Never>? {
        guard !isTerminating else { return nil }
        let id = UUID()
        activeOperations.insert(id)
        return Task { @MainActor in
            defer { complete(id) }
            await operation()
        }
    }

    /// Close admission in the AppKit termination callback, before it returns.
    func beginTermination() -> Bool {
        guard !isTerminating else { return false }
        isTerminating = true
        return true
    }

    func finishTermination(
        flush: @MainActor () async throws -> Void,
        shutdown: @MainActor () async -> Void
    ) async throws {
        await waitForActiveWork()
        do {
            try await flush()
        } catch {
            // A failed save cancels quitting; leave the engine available so the
            // user can recover rather than exiting with a false success signal.
            isTerminating = false
            throw error
        }
        await shutdown()
    }

    func waitForActiveWork() async {
        guard !activeOperations.isEmpty else { return }
        await withCheckedContinuation { idleWaiters.append($0) }
    }

    private func complete(_ id: UUID) {
        activeOperations.remove(id)
        guard activeOperations.isEmpty else { return }
        let waiters = idleWaiters
        idleWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
    }
}
