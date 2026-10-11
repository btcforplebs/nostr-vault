import Foundation

/// A one-at-a-time gate for background signer requests.
///
/// Each holder gets a ticket, and only that ticket can release the slot, once.
/// That lets a holder's slot be taken back on a timer (`lease`) while its
/// request is still waiting on the signer, without its later release freeing
/// the slot out from under whoever got it next.
actor SignerRequestGate {
    private var holder: UInt64?
    private var nextTicket: UInt64 = 0
    private var waiters: [(ticket: UInt64, continuation: CheckedContinuation<Void, Never>)] = []

    func wait() async -> UInt64 {
        nextTicket += 1
        let ticket = nextTicket
        if holder == nil { holder = ticket; return ticket }
        await withCheckedContinuation { waiters.append((ticket, $0)) }
        return ticket
    }

    /// Frees the slot if `ticket` still holds it; otherwise does nothing.
    func signal(_ ticket: UInt64) {
        guard holder == ticket else { return }
        if waiters.isEmpty {
            holder = nil
        } else {
            let next = waiters.removeFirst()
            holder = next.ticket
            next.continuation.resume()
        }
    }
}
