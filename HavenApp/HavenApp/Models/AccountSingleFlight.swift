import Foundation

/// One run of `work` at a time per account. A caller for the same account
/// waits for the running one; a caller for another account (a switch
/// meanwhile) waits, then runs its own.
@MainActor
final class AccountSingleFlight {
    private var inFlight: (account: String, id: UUID, task: Task<Void, Never>)?

    /// `currentAccount` is read after a wait: if the account changed again,
    /// the waiter's run is stale and skipped.
    func run(
        account: String,
        currentAccount: () -> String,
        _ work: @escaping @MainActor () async -> Void
    ) async {
        while let running = inFlight {
            await running.task.value
            // The waiter can resume before the owner clears the slot, and
            // awaiting a finished task does not suspend: drop it here or
            // the loop spins on the main actor.
            if inFlight?.id == running.id { inFlight = nil }
            if running.account == account || currentAccount() != account { return }
        }
        let id = UUID()
        let task = Task { @MainActor in await work() }
        inFlight = (account, id, task)
        await task.value
        // Only the run that set the slot clears it.
        if inFlight?.id == id { inFlight = nil }
    }
}
