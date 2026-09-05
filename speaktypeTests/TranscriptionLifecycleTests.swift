import XCTest

@testable import speaktype

@MainActor
final class TranscriptionLifecycleTests: XCTestCase {
    private enum TestError: Error {
        case flushFailed
    }

    // `perform` must register the operation before creating work that can be
    // scheduled later. Otherwise immediate termination can flush and shut down
    // while the just-submitted transcription is still pending.
    func testFinishTerminationWaitsForRegisteredButNotStartedOperation() async throws {
        let lifecycle = TranscriptionLifecycle()
        var events: [String] = []

        let operation = try XCTUnwrap(lifecycle.perform {
            events.append("operation")
        })
        XCTAssertTrue(lifecycle.beginTermination())

        try await lifecycle.finishTermination(
            flush: { events.append("flush") },
            shutdown: { events.append("shutdown") }
        )
        await operation.value

        XCTAssertEqual(events, ["operation", "flush", "shutdown"])
    }

    // A transcription is not finished when decoding returns; its queued save
    // must also complete before termination flushes persistent history.
    func testFinishTerminationWaitsForSuspendedSaveCompletion() async throws {
        let lifecycle = TranscriptionLifecycle()
        let saveGate = ContinuationGate()
        let terminationStarted = AsyncSignal()
        var events: [String] = []

        let operation = try XCTUnwrap(lifecycle.perform {
            events.append("transcriptionResult")
            await saveGate.wait()
            events.append("saveComplete")
        })
        await saveGate.waitUntilWaiting()
        XCTAssertTrue(lifecycle.beginTermination())

        let termination = Task {
            terminationStarted.signal()
            try await lifecycle.finishTermination(
                flush: { events.append("flush") },
                shutdown: { events.append("shutdown") }
            )
        }
        await terminationStarted.wait()

        XCTAssertEqual(events, ["transcriptionResult"])

        saveGate.resume()
        await operation.value
        try await termination.value

        XCTAssertEqual(
            events,
            ["transcriptionResult", "saveComplete", "flush", "shutdown"]
        )
    }

    func testFinishTerminationWaitsForAllRegisteredOperations() async throws {
        let lifecycle = TranscriptionLifecycle()
        let firstGate = ContinuationGate()
        let secondGate = ContinuationGate()
        let terminationStarted = AsyncSignal()
        var events: [String] = []

        let firstOperation = try XCTUnwrap(lifecycle.perform {
            await firstGate.wait()
            events.append("firstComplete")
        })
        let secondOperation = try XCTUnwrap(lifecycle.perform {
            await secondGate.wait()
            events.append("secondComplete")
        })
        await firstGate.waitUntilWaiting()
        await secondGate.waitUntilWaiting()
        XCTAssertTrue(lifecycle.beginTermination())

        let termination = Task {
            terminationStarted.signal()
            try await lifecycle.finishTermination(
                flush: { events.append("flush") },
                shutdown: { events.append("shutdown") }
            )
        }
        await terminationStarted.wait()
        XCTAssertTrue(events.isEmpty)

        firstGate.resume()
        await firstOperation.value
        await Task.yield()
        XCTAssertEqual(events, ["firstComplete"])

        secondGate.resume()
        await secondOperation.value
        try await termination.value

        XCTAssertEqual(
            events,
            ["firstComplete", "secondComplete", "flush", "shutdown"]
        )
    }

    func testPerformRejectsNewWorkAfterTerminationBegins() async throws {
        let lifecycle = TranscriptionLifecycle()
        var rejectedOperationRan = false

        XCTAssertTrue(lifecycle.beginTermination())
        let operation = lifecycle.perform {
            rejectedOperationRan = true
        }

        XCTAssertNil(operation)
        try await lifecycle.finishTermination(flush: {}, shutdown: {})
        XCTAssertFalse(rejectedOperationRan)
    }

    func testFinishTerminationFlushFailureSkipsShutdownAndAllowsRetry() async throws {
        let lifecycle = TranscriptionLifecycle()
        var events: [String] = []

        XCTAssertTrue(lifecycle.beginTermination())
        do {
            try await lifecycle.finishTermination(
                flush: {
                    events.append("failedFlush")
                    throw TestError.flushFailed
                },
                shutdown: { events.append("unexpectedShutdown") }
            )
            XCTFail("Expected the flush error to be rethrown")
        } catch TestError.flushFailed {
            // Expected.
        }

        XCTAssertEqual(events, ["failedFlush"])
        XCTAssertFalse(lifecycle.isTerminating)

        let operation = try XCTUnwrap(lifecycle.perform {
            events.append("operationAfterFailure")
        })
        await operation.value

        XCTAssertTrue(lifecycle.beginTermination())
        try await lifecycle.finishTermination(
            flush: { events.append("retryFlush") },
            shutdown: { events.append("retryShutdown") }
        )

        XCTAssertEqual(
            events,
            ["failedFlush", "operationAfterFailure", "retryFlush", "retryShutdown"]
        )
        XCTAssertTrue(lifecycle.isTerminating)
    }

    func testFinishTerminationWithoutWorkFlushesBeforeShutdown() async throws {
        let lifecycle = TranscriptionLifecycle()
        var events: [String] = []

        XCTAssertTrue(lifecycle.beginTermination())
        try await lifecycle.finishTermination(
            flush: { events.append("flush") },
            shutdown: { events.append("shutdown") }
        )

        XCTAssertEqual(events, ["flush", "shutdown"])
        XCTAssertTrue(lifecycle.isTerminating)
    }

    func testBeginTerminationReturnsFalseWhenAlreadyTerminating() async throws {
        let lifecycle = TranscriptionLifecycle()

        XCTAssertTrue(lifecycle.beginTermination())
        XCTAssertFalse(lifecycle.beginTermination())

        try await lifecycle.finishTermination(flush: {}, shutdown: {})
        XCTAssertFalse(lifecycle.beginTermination())
    }
}

@MainActor
private final class ContinuationGate {
    private var bufferedResume = false
    private var continuation: CheckedContinuation<Void, Never>?
    private var waitingObservers: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        if bufferedResume {
            bufferedResume = false
            return
        }

        await withCheckedContinuation { continuation in
            precondition(self.continuation == nil, "ContinuationGate supports one waiter")
            self.continuation = continuation

            let observers = waitingObservers
            waitingObservers.removeAll()
            for observer in observers {
                observer.resume()
            }
        }
    }

    func waitUntilWaiting() async {
        guard continuation == nil else { return }
        await withCheckedContinuation { continuation in
            waitingObservers.append(continuation)
        }
    }

    func resume() {
        guard let continuation else {
            bufferedResume = true
            return
        }

        self.continuation = nil
        continuation.resume()
    }
}

@MainActor
private final class AsyncSignal {
    private var bufferedSignal = false
    private var continuation: CheckedContinuation<Void, Never>?

    func wait() async {
        if bufferedSignal {
            bufferedSignal = false
            return
        }

        await withCheckedContinuation { continuation in
            precondition(self.continuation == nil, "AsyncSignal supports one waiter")
            self.continuation = continuation
        }
    }

    func signal() {
        guard let continuation else {
            bufferedSignal = true
            return
        }

        self.continuation = nil
        continuation.resume()
    }
}
