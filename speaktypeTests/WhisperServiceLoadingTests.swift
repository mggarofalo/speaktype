import XCTest
@testable import speaktype

@MainActor
final class WhisperServiceLoadingTests: XCTestCase {
    // The first recording used to reject a matching startup warmup as "already
    // loading." It must join that work and remain suspended until it completes.
    func testInitializeJoinsMatchingWarmupAndBothAwaitSuccess() async throws {
        let loader = SuspendedModelLoader()
        let selection = EngineSelection(.whispercpp)
        let service = makeService(loader: loader, selection: selection)
        service.currentModelVariant = "shared-variant"
        let warmup = Task { @MainActor in
            try await service.loadModel(variant: "shared-variant")
        }
        await loader.waitForAttemptCount(1)

        let recordingEntered = MainActorSignal()
        let recordingCompletion = CompletionFlag()
        let recording = Task { @MainActor in
            recordingEntered.signal()
            try await service.initialize()
            recordingCompletion.markCompleted()
        }
        await recordingEntered.wait()
        let attemptCount = loader.requestCount
        XCTAssertTrue(service.isLoading)
        XCTAssertFalse(service.isInitialized)
        XCTAssertFalse(recordingCompletion.isCompleted)
        loader.succeedAllPending()

        try await warmup.value
        try await recording.value
        XCTAssertEqual(attemptCount, 1)
        XCTAssertEqual(loader.requests, [
            LoadRequest(engine: .whispercpp, variant: "shared-variant")
        ])
        XCTAssertTrue(service.isInitialized)
        XCTAssertFalse(service.isLoading)
        XCTAssertEqual(service.loadingStage, "")
    }

    func testLoadModelFailureFansOutAndLaterRetryStartsFreshLoad() async throws {
        let loader = SuspendedModelLoader()
        let selection = EngineSelection(.whisperkit)
        let service = makeService(loader: loader, selection: selection)
        let first = Task { @MainActor in
            try await service.loadModel(variant: "retry-variant")
        }
        await loader.waitForAttemptCount(1)
        let secondEntered = MainActorSignal()
        let second = Task { @MainActor in
            secondEntered.signal()
            try await service.loadModel(variant: "retry-variant")
        }
        await secondEntered.wait()
        let failedAttemptCount = loader.requestCount
        loader.failAllPending(with: SimulatedModelLoadFailure())

        await assertSimulatedFailure(first)
        await assertSimulatedFailure(second)
        XCTAssertEqual(failedAttemptCount, 1)
        XCTAssertFalse(service.isInitialized)
        XCTAssertFalse(service.isLoading)
        XCTAssertEqual(service.loadingStage, "")

        let retryAttempt = loader.requestCount + 1
        let retry = Task { @MainActor in
            try await service.loadModel(variant: "retry-variant")
        }
        await loader.waitForAttemptCount(retryAttempt)
        loader.succeedAllPending()
        try await retry.value

        XCTAssertEqual(loader.requestCount, 2)
        XCTAssertTrue(service.isInitialized)
        XCTAssertFalse(service.isLoading)
        XCTAssertEqual(service.currentModelVariant, "retry-variant")
    }

    func testLoadModelRejectsConflictingVariantAndEngineDuringActiveLoad() async throws {
        let loader = SuspendedModelLoader()
        let selection = EngineSelection(.whispercpp)
        let service = makeService(loader: loader, selection: selection)
        let active = Task { @MainActor in
            try await service.loadModel(variant: "active-variant")
        }
        await loader.waitForAttemptCount(1)

        do {
            try await service.loadModel(variant: "different-variant")
            XCTFail("A different variant must not replace an active load")
        } catch WhisperService.TranscriptionError.alreadyLoading {
        } catch {
            XCTFail("Unexpected variant-conflict error: \(error)")
        }

        selection.engine = .whisperkit
        do {
            try await service.loadModel(variant: "active-variant")
            XCTFail("A different engine must not join an active load")
        } catch WhisperService.TranscriptionError.alreadyLoading {
        } catch {
            XCTFail("Unexpected engine-conflict error: \(error)")
        }

        let attemptCount = loader.requestCount
        selection.engine = .whispercpp
        loader.succeedAllPending()
        try await active.value

        XCTAssertEqual(attemptCount, 1)
        XCTAssertEqual(loader.requestCount, 1)
        XCTAssertTrue(service.isInitialized)
        XCTAssertEqual(service.currentModelVariant, "active-variant")
    }

    func testLoadedModelCacheIncludesEngineAsWellAsVariant() async throws {
        let loader = RecordingModelLoader()
        let selection = EngineSelection(.whispercpp)
        let service = WhisperService(
            modelLoader: { engine, variant in loader.load(engine: engine, variant: variant) },
            engineSelector: { selection.engine })

        try await service.loadModel(variant: "same-variant")
        try await service.loadModel(variant: "same-variant")
        selection.engine = .whisperkit
        try await service.loadModel(variant: "same-variant")

        XCTAssertEqual(loader.requests, [
            LoadRequest(engine: .whispercpp, variant: "same-variant"),
            LoadRequest(engine: .whisperkit, variant: "same-variant")
        ])
        XCTAssertTrue(service.isInitialized)
        XCTAssertEqual(service.currentModelVariant, "same-variant")
    }

    func testCancelingJoinedWaiterDoesNotCancelSharedLoad() async throws {
        let loader = SuspendedModelLoader()
        let selection = EngineSelection(.whispercpp)
        let service = makeService(loader: loader, selection: selection)
        let owner = Task { @MainActor in
            try await service.loadModel(variant: "cancel-variant")
        }
        await loader.waitForAttemptCount(1)
        let waiterEntered = MainActorSignal()
        let waiter = Task { @MainActor in
            waiterEntered.signal()
            try await service.loadModel(variant: "cancel-variant")
        }
        await waiterEntered.wait()

        waiter.cancel()
        let attemptCount = loader.requestCount
        loader.succeedAllPending()
        try await owner.value
        _ = await waiter.result

        XCTAssertEqual(attemptCount, 1)
        XCTAssertEqual(loader.requestCount, 1)
        XCTAssertEqual(loader.wasCancelledWhenResumed, [false])
        XCTAssertTrue(service.isInitialized)
        XCTAssertFalse(service.isLoading)
    }

    func testCancelingLoadOwnerDoesNotCancelSharedLoadForJoinedWaiter() async throws {
        let loader = SuspendedModelLoader()
        let selection = EngineSelection(.whispercpp)
        let service = makeService(loader: loader, selection: selection)
        let owner = Task { @MainActor in
            try await service.loadModel(variant: "owner-cancel-variant")
        }
        await loader.waitForAttemptCount(1)
        let waiterEntered = MainActorSignal()
        let waiter = Task { @MainActor in
            waiterEntered.signal()
            try await service.loadModel(variant: "owner-cancel-variant")
        }
        await waiterEntered.wait()

        owner.cancel()
        let attemptCount = loader.requestCount
        loader.succeedAllPending()
        try await waiter.value
        _ = await owner.result

        XCTAssertEqual(attemptCount, 1)
        XCTAssertEqual(loader.requestCount, 1)
        XCTAssertEqual(loader.wasCancelledWhenResumed, [false])
        XCTAssertTrue(service.isInitialized)
        XCTAssertFalse(service.isLoading)
    }

    private func makeService(
        loader: SuspendedModelLoader,
        selection: EngineSelection
    ) -> WhisperService {
        WhisperService(
            modelLoader: { engine, variant in
                try await loader.load(engine: engine, variant: variant)
            },
            engineSelector: { selection.engine })
    }

    private func assertSimulatedFailure(
        _ task: Task<Void, Error>,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        do {
            try await task.value
            XCTFail("Expected model loading to fail", file: file, line: line)
        } catch is SimulatedModelLoadFailure {
        } catch {
            XCTFail("Unexpected load error: \(error)", file: file, line: line)
        }
    }
}

private struct LoadRequest: Equatable {
    let engine: TranscriptionEngineKind
    let variant: String
}

@MainActor
private final class EngineSelection {
    var engine: TranscriptionEngineKind

    init(_ engine: TranscriptionEngineKind) {
        self.engine = engine
    }
}

@MainActor
private final class MainActorSignal {
    private var hasSignaled = false
    private var continuation: CheckedContinuation<Void, Never>?

    func signal() {
        hasSignaled = true
        continuation?.resume()
        continuation = nil
    }

    func wait() async {
        guard !hasSignaled else { return }
        await withCheckedContinuation { continuation = $0 }
    }
}

@MainActor
private final class CompletionFlag {
    private(set) var isCompleted = false

    func markCompleted() {
        isCompleted = true
    }
}

@MainActor
private final class SuspendedModelLoader {
    private(set) var requests: [LoadRequest] = []
    private(set) var wasCancelledWhenResumed: [Bool] = []
    private var pending: [Int: CheckedContinuation<Void, Error>] = [:]
    private var attemptWaiters: [(count: Int, continuation: CheckedContinuation<Void, Never>)] = []

    var requestCount: Int { requests.count }

    func load(engine: TranscriptionEngineKind, variant: String) async throws {
        let attempt = requests.count + 1
        try await withCheckedThrowingContinuation { continuation in
            requests.append(LoadRequest(engine: engine, variant: variant))
            pending[attempt] = continuation
            resumeSatisfiedAttemptWaiters()
        }
        wasCancelledWhenResumed.append(Task.isCancelled)
    }

    func waitForAttemptCount(_ count: Int) async {
        guard requests.count < count else { return }
        await withCheckedContinuation { continuation in
            attemptWaiters.append((count, continuation))
        }
    }

    func succeedAllPending() {
        let continuations = Array(pending.values)
        pending.removeAll()
        continuations.forEach { $0.resume() }
    }

    func failAllPending(with error: Error) {
        let continuations = Array(pending.values)
        pending.removeAll()
        continuations.forEach { $0.resume(throwing: error) }
    }

    private func resumeSatisfiedAttemptWaiters() {
        let ready = attemptWaiters.filter { requests.count >= $0.count }
        attemptWaiters.removeAll { requests.count >= $0.count }
        ready.forEach { $0.continuation.resume() }
    }
}

@MainActor
private final class RecordingModelLoader {
    private(set) var requests: [LoadRequest] = []

    func load(engine: TranscriptionEngineKind, variant: String) {
        requests.append(LoadRequest(engine: engine, variant: variant))
    }
}

private struct SimulatedModelLoadFailure: Error {}
