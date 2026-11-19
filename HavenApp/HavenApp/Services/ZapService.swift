import Foundation
import Combine

@MainActor
class ZapService: ObservableObject {
    static let shared = ZapService()
    
    private init() {}

    /// Zaps sent but not yet confirmed by the wallet or a receipt (ZapPendingGuard).
    private var pending = ZapPendingGuard()
    
    enum ZapError: Error, LocalizedError {
        case lnurlResolutionFailed
        case invoiceFetchFailed
        case paymentFailed(String)
        case signFailed
        /// The provider's invoice was not for the amount asked (ZapInvoiceCheck).
        case wrongInvoiceAmount
        case invoiceExpired
        /// Sent to the wallet, no answer yet. The zap pill says so and turns to Zapped when our
        /// receipt arrives; not a failure, so callers don't report it as one.
        case pending
        /// A second zap to the same thing was declined at "Zap again?".
        case notRepeated

        /// Neither a payment nor a failure to report: `pending` and `notRepeated`.
        var isQuiet: Bool {
            switch self {
            case .pending, .notRepeated: return true
            default: return false
            }
        }

        var errorDescription: String? {
            switch self {
            case .lnurlResolutionFailed: return "Failed to resolve Lightning Address"
            case .invoiceFetchFailed: return "Failed to fetch invoice from provider"
            case .wrongInvoiceAmount: return "The zap server asked for a different amount. Nothing was paid."
            case .invoiceExpired: return "The zap server's invoice had already expired. Nothing was paid."
            case .paymentFailed(let msg): return "Payment failed: \(msg)"
            case .signFailed: return "Failed to sign Zap Request"
            case .pending: return "Sent to your wallet. Waiting for it to confirm."
            case .notRepeated: return "Not zapped again."
            }
        }
    }
    
    /// Where a zap's receipt should be published. Your own relay is listed
    /// only when it is public: a provider cannot reach a loopback or LAN
    /// address, so listing it there only wasted a slot.
    /// - Parameter extra: relays someone else needs to find the receipt on —
    ///   a gated article's key server reads the relays its author named — so
    ///   they go first and are never the ones the cap cuts.
    static func receiptRelays(me: String, recipient: String, extra: [String] = []) -> [String] {
        let config = ConfigService.shared.config
        let lists = NostrService.shared.relayLists
        var candidates = extra + [config.nostrURL]
        candidates += config.readRelays
        candidates += lists[me] ?? []
        candidates += (lists[recipient] ?? []).prefix(3)
        var seen = Set<String>()
        return Array(candidates
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { isPublicRelay($0) && seen.insert($0.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "/"))).inserted }
            .prefix(10))
    }

    static func isPublicRelay(_ url: String) -> Bool {
        guard let host = URL(string: url)?.host?.lowercased(), !host.isEmpty else { return false }
        if host == "localhost" || host.hasSuffix(".local") || host == "::1" { return false }
        let octets = host.split(separator: ".").compactMap { Int($0) }
        if octets.count == 4 {
            switch (octets[0], octets[1]) {
            case (127, _), (10, _), (192, 168), (169, 254), (0, _): return false
            case (172, 16...31), (100, 64...127): return false
            default: return true
            }
        }
        return true
    }

    /// Executes a full Zap flow: LNURL -> Zap Request -> Invoice -> NWC Payment
    /// - Parameter addressTag: `a` address (`kind:pubkey:d`) of an addressable event the
    ///   zap belongs to. A live stream is the case that needs it: clients count
    ///   a stream's zaps by its address, so a receipt with only `e` and `p` is
    ///   invisible on the stream it paid for.
    /// - Parameter extraReceiptRelays: see `receiptRelays(me:recipient:extra:)`.
    func zapNote(noteId: String, notePubkey: String, lud16: String, amountSats: Int? = nil, message: String = "", addressTag: String? = nil, extraReceiptRelays: [String] = []) async throws {
        let amountSats = amountSats ?? (ConfigService.shared.config.quickZapSats)
        guard amountSats > 0 else {
            throw ZapError.paymentFailed("Zap amount must be greater than 0")
        }
        guard amountSats <= 10_000_000 else {
            throw ZapError.paymentFailed("Zap amount exceeds safety limit")
        }
        let amountMsat = amountSats * 1000
        
        let recipientName = NostrService.shared.profiles[notePubkey]?.bestName ?? String(notePubkey.prefix(8))
        let pendingKey = ZapPendingGuard.key(noteId: noteId, address: addressTag, pubkey: notePubkey)
        if pending.isPending(pendingKey) {
            RelayProcessManager.shared.addLog("Zap: last zap to \(lud16) not confirmed yet; asking before zapping again", level: "INFO")
            guard await ZapRepeatPrompt.confirm(recipientName: recipientName) else { throw ZapError.notRepeated }
        }
        let notifId = ZapNotificationManager.shared.addZap(recipientName: recipientName, amountSats: amountSats)
        
        RelayProcessManager.shared.addLog("Zap: Starting zap for \(lud16) (\(amountSats) sats)", level: "INFO")
        
        do {
            // 1. Resolve LNURL — supports both LUD-16 (user@domain.com) and LUD-06 (bech32 lnurl1...)
            let lnurlResponse: LNURLService.LNURLPayResponse
            do {
                if lud16.lowercased().hasPrefix("lnurl:") {
                    // LUD-06: raw bech32-encoded LNURL stored with "lnurl:" sentinel prefix
                    lnurlResponse = try await LNURLService.resolveRawLNURL(lud16)
                } else {
                    // LUD-16: user@domain.com lightning address
                    lnurlResponse = try await LNURLService.resolveAddress(lud16)
                }
            } catch {
                RelayProcessManager.shared.addLog("Zap: LNURL resolution failed: \(error.localizedDescription)", level: "ERROR")
                throw ZapError.lnurlResolutionFailed
            }
            
            // 2. Build Zap Request (Kind 9734)
            // The provider publishes the receipt to these relays, so they must
            // be ones it can reach and that get read: the relays Given and the
            // feed query, your published inbox, and the recipient's inbox.
            let relayList = Self.receiptRelays(me: NostrService.shared.activeHexPubkey, recipient: notePubkey,
                                                extra: extraReceiptRelays)

            var tags: [[String]] = [
                ["p", notePubkey],
                ["relays"] + relayList,
                ["amount", String(amountMsat)]
            ]
            
            if !noteId.isEmpty {
                tags.append(["e", noteId])
            }

            if let addressTag, !addressTag.isEmpty {
                tags.append(["a", addressTag, extraReceiptRelays.first ?? LiveChat.streamRelay])
            }
            
            // Add lnurl tag — strip internal sentinel prefix if present
            let lnurlTag = lud16.lowercased().hasPrefix("lnurl:") ? String(lud16.dropFirst(6)) : lud16
            tags.append(["lnurl", lnurlTag])
            
            guard let signedZapReq = await NostrService.shared.signEventAsync(kind: 9734, content: ZapComment.content(message), tags: tags) else {
                RelayProcessManager.shared.addLog("Zap: Failed to sign Zap Request", level: "ERROR")
                throw ZapError.signFailed
            }
            
            // 3. Fetch Invoice
            let invoice: String
            do {
                invoice = try await LNURLService.fetchInvoice(
                    callback: lnurlResponse.callback,
                    amountMsat: amountMsat,
                    zapRequest: signedZapReq
                )
            } catch {
                RelayProcessManager.shared.addLog("Zap: Invoice fetch failed: \(error.localizedDescription)", level: "ERROR")
                throw ZapError.invoiceFetchFailed
            }
            
            // 4. Never pay more than was asked, or a dead invoice (LUD-06).
            switch ZapInvoiceCheck.problem(invoice: invoice, amountMsat: amountMsat) {
            case .wrongAmount?:
                RelayProcessManager.shared.addLog("Zap: invoice amount does not match \(amountMsat) msat; not paying", level: "ERROR")
                throw ZapError.wrongInvoiceAmount
            case .expired?:
                RelayProcessManager.shared.addLog("Zap: invoice already expired; not paying", level: "ERROR")
                throw ZapError.invoiceExpired
            case nil:
                break
            }

            // 5. Pay via NWC, and look for our receipt at the same time: whichever says paid first
            // wins. A wallet that hasn't answered may still pay (Minibits review, 2026-11-19).
            pending.begin(pendingKey)
            let receipt = ZapReceiptWatcher.Zap(zapRequest: signedZapReq, invoice: invoice, recipient: notePubkey,
                                                noteId: noteId, publisher: lnurlResponse.nostrPubkey, relays: relayList)
            switch await payAndWatch(invoice: invoice, receipt: receipt) {
            case .paid(let preimage):
                RelayProcessManager.shared.addLog("Zap: Successfully paid! Preimage: \(preimage)", level: "INFO")
                pending.end(pendingKey)
                ZapNotificationManager.shared.markSuccess(id: notifId)
            case .receipt:
                RelayProcessManager.shared.addLog("Zap: paid (receipt seen before the wallet answered)", level: "INFO")
                pending.end(pendingKey)
                ZapNotificationManager.shared.markSuccess(id: notifId)
            case .mayStillSettle(let error, let watch):
                RelayProcessManager.shared.addLog("Zap: \(error.localizedDescription) Waiting for the receipt.", level: "WARN")
                ZapNotificationManager.shared.markPending(id: notifId)
                Task { @MainActor [weak self] in
                    let found = await watch.value
                    self?.settlePending(found: found, key: pendingKey, notifId: notifId, noteId: noteId, amountSats: amountSats)
                }
                throw ZapError.pending
            case .failed(let error):
                pending.end(pendingKey)
                RelayProcessManager.shared.addLog("Zap: NWC Payment failed: \(error.localizedDescription)", level: "ERROR")
                throw ZapError.paymentFailed(error.localizedDescription)
            }
        } catch {
            if (error as? ZapError)?.isQuiet != true {
                ZapNotificationManager.shared.markFailed(id: notifId, message: error.localizedDescription)
            }
            throw error
        }
    }

    /// What paying an invoice came to: the wallet's answer or our receipt, whichever came first.
    private enum PayResult {
        case paid(String)
        case receipt
        /// The wallet didn't say paid or failed. `watch` is still looking for the receipt.
        case mayStillSettle(Error, Task<Bool, Never>)
        case failed(Error)
    }

    private final class Once {
        var done = false
        var walletAnswered = false
    }

    private func payAndWatch(invoice: String, receipt: ZapReceiptWatcher.Zap) async -> PayResult {
        let once = Once()
        let watch = Task { @MainActor in
            await ZapReceiptWatcher.waitForReceipt(receipt, stop: { once.walletAnswered })
        }
        return await withCheckedContinuation { (continuation: CheckedContinuation<PayResult, Never>) in
            @MainActor func finish(_ result: PayResult) {
                guard !once.done else { return }
                once.done = true
                continuation.resume(returning: result)
            }
            Task { @MainActor in
                do {
                    let preimage = try await NWCService.payInvoice(bolt11: invoice)
                    once.walletAnswered = true
                    finish(.paid(preimage))
                } catch let error as NWCService.NWCError where error.mayStillSettle {
                    finish(.mayStillSettle(error, watch))
                } catch {
                    once.walletAnswered = true
                    finish(.failed(error))
                }
            }
            Task { @MainActor in
                if await watch.value { finish(.receipt) }
            }
        }
    }

    /// A zap that was still on its way: the receipt makes it Zapped, bolt lit; no receipt in
    /// `ZapWait.receipt` leaves it "not confirmed", and a second zap keeps asking first until
    /// `ZapPendingGuard.window` passes.
    private func settlePending(found: Bool, key: String, notifId: UUID, noteId: String, amountSats: Int) {
        guard found else {
            RelayProcessManager.shared.addLog("Zap: no receipt in \(Int(ZapWait.receipt))s; not confirmed", level: "WARN")
            ZapNotificationManager.shared.markUnconfirmed(id: notifId)
            return
        }
        pending.end(key)
        ZapNotificationManager.shared.markSuccess(id: notifId)
        guard !noteId.isEmpty else { return }
        FeedService.shared.zappedEventIds[noteId] = amountSats
        FeedService.shared.saveInteractionState()
    }
}
