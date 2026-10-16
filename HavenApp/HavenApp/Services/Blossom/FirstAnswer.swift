import Foundation

/// Runs jobs side by side and hands back the first one that succeeds, without
/// waiting for the others. The rest keep running to the end on their own
/// (unstructured tasks), so a post goes out as soon as one Blossom server has
/// the file while the other servers still get their copy. A server that hangs
/// can no longer hold the post: before, the upload pass waited for every
/// server and posted the first in list order.
enum FirstAnswer {
    /// The first non-nil result, or nil once every job has finished with nil.
    /// `onLate` sees each result that arrives after the winner (for logging).
    /// `onAllDone` runs once every job has finished, winner or not (to
    /// delete a file the stragglers were still reading).
    static func first<T: Sendable>(
        _ jobs: [@Sendable () async -> T?],
        onLate: (@Sendable (Int, T?) -> Void)? = nil,
        onAllDone: (@Sendable () -> Void)? = nil
    ) async -> T? {
        guard !jobs.isEmpty else { onAllDone?(); return nil }
        let state = Race<T>(count: jobs.count, onLate: onLate, onAllDone: onAllDone)
        return await withCheckedContinuation { continuation in
            Task { await state.start(continuation) }
            for (index, job) in jobs.enumerated() {
                Task {
                    let result = await job()
                    await state.finished(index, result)
                }
            }
        }
    }

    private actor Race<T: Sendable> {
        private var remaining: Int
        private var continuation: CheckedContinuation<T?, Never>?
        private var early: [(Int, T?)] = []
        private var answered = false
        private let onLate: (@Sendable (Int, T?) -> Void)?
        private let onAllDone: (@Sendable () -> Void)?

        init(count: Int, onLate: (@Sendable (Int, T?) -> Void)?, onAllDone: (@Sendable () -> Void)?) {
            remaining = count
            self.onLate = onLate
            self.onAllDone = onAllDone
        }

        func start(_ continuation: CheckedContinuation<T?, Never>) {
            self.continuation = continuation
            let pending = early
            early = []
            for (index, result) in pending { settle(index, result) }
        }

        func finished(_ index: Int, _ result: T?) {
            // A job can finish before `start` has stored the continuation.
            guard continuation != nil || answered else {
                early.append((index, result))
                return
            }
            settle(index, result)
        }

        private func settle(_ index: Int, _ result: T?) {
            remaining -= 1
            if answered {
                onLate?(index, result)
            } else if result != nil || remaining == 0 {
                answered = true
                continuation?.resume(returning: result)
                continuation = nil
            }
            if remaining == 0 { onAllDone?() }
        }
    }
}
