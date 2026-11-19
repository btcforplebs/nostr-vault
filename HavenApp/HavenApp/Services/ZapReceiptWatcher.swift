import Foundation

/// Looks for our own zap receipt (kind 9735) after paying, so a zap the wallet paid but never
/// answered for, or answered without a preimage, still shows as zapped
/// (RESEARCH/NV_MINIBITS_ZAP_REVIEW_2026_11_19.md, bug 2). The receipt is the proof every
/// wallet and every zap server gives.
@MainActor
enum ZapReceiptWatcher {
    struct Zap {
        let zapRequest: NostrEvent
        let invoice: String
        let recipient: String
        let noteId: String
        /// The recipient's LNURL `nostrPubkey`: only its receipts count.
        let publisher: String?
        /// Where we asked the server to publish the receipt (the 9734's `relays`).
        let relays: [String]
    }

    /// True once a matching receipt is seen, false when `ZapWait.receipt` passes without one or
    /// `stop()` says the wallet answered first.
    static func waitForReceipt(_ zap: Zap, stop: @escaping () -> Bool = { false }) async -> Bool {
        let deadline = Date().addingTimeInterval(ZapWait.receipt)
        var filter: [String: Any] = [
            "kinds": [9735],
            "#p": [zap.recipient],
            "since": Int(zap.zapRequest.created_at) - 10,
            "limit": 50,
        ]
        if !zap.noteId.isEmpty { filter["#e"] = [zap.noteId] }
        while Date() < deadline, !stop(), !Task.isCancelled {
            let events = await NostrService.shared.fetchEvents(filter: filter, from: zap.relays, timeout: ZapWait.receiptPoll)
            if events.contains(where: {
                $0.kind == 9735 && ZapReceiptMatch.matches(receiptPubkey: $0.pubkey, tags: $0.tags, zapRequestId: zap.zapRequest.id,
                                                           invoice: zap.invoice, publisher: zap.publisher)
            }) {
                RelayProcessManager.shared.addLog("Zap: receipt found for request \(zap.zapRequest.id.prefix(12))", level: "INFO")
                return true
            }
            if stop() { break }
            try? await Task.sleep(nanoseconds: UInt64(ZapWait.receiptPoll * 1_000_000_000))
        }
        return false
    }
}
