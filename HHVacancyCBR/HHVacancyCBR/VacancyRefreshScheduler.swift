import Foundation

/// Serializes full refreshes without polling or blocking the main thread.
@MainActor enum VacancyRefreshScheduler {
    private struct Waiter {
        let id: UUID
        let continuation: CheckedContinuation<Void, Error>
    }
    private static var busy = false
    private static var waiters: [Waiter] = []

    static func acquire() async throws {
        try Task.checkCancellation()
        if !busy { busy = true; return }
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                if Task.isCancelled {
                    continuation.resume(throwing: CancellationError())
                } else {
                    waiters.append(Waiter(id: id, continuation: continuation))
                }
            }
        } onCancel: {
            Task { @MainActor in cancel(id) }
        }
        // Cancellation can race with ownership transfer. Return the permit.
        if Task.isCancelled { release(); throw CancellationError() }
    }

    private static func cancel(_ id: UUID) {
        guard let index = waiters.firstIndex(where: { $0.id == id }) else { return }
        waiters.remove(at: index).continuation.resume(throwing: CancellationError())
    }

    static func release() {
        if waiters.isEmpty { busy = false }
        else { waiters.removeFirst().continuation.resume() }
    }
}
