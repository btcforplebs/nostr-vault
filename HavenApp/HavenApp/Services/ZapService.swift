import Foundation
import Combine

@MainActor
class ZapService: ObservableObject {
    static let shared = ZapService()
    
    private init() {}
    
    enum ZapError: Error, LocalizedError {
        case lnurlResolutionFailed
        case invoiceFetchFailed
        case paymentFailed(String)
        case signFailed
        
        var errorDescription: String? {
            switch self {
            case .lnurlResolutionFailed: return "Failed to resolve Lightning Address"
            case .invoiceFetchFailed: return "Failed to fetch invoice from provider"
            case .paymentFailed(let msg): return "Payment failed: \(msg)"
            case .signFailed: return "Failed to sign Zap Request"
            }
        }
    }
    
    /// Where a zap's receipt should be published. Your own relay is listed
    /// only when it is public: a provider cannot reach a loopback or LAN
    /// address, so listing it there only wasted a slot.
    static func receiptRelays(me: String, recipient: String) -> [String] {
        let config = ConfigService.shared.config
        let lists = NostrService.shared.relayLists
        var candidates = [config.nostrURL]
        candidates += config.activeFeedRelays.isEmpty ? ["wss://relay.primal.net", "wss://nos.lol"] : config.activeFeedRelays
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
    func zapNote(noteId: String, notePubkey: String, lud16: String, amountSats: Int? = nil, message: String = "Zap from Nostr Vault", addressTag: String? = nil) async throws {
        let amountSats = amountSats ?? (ConfigService.shared.config.defaultZapAmount / 1000)
        guard amountSats > 0 else {
            throw ZapError.paymentFailed("Zap amount must be greater than 0")
        }
        guard amountSats <= 10_000_000 else {
            throw ZapError.paymentFailed("Zap amount exceeds safety limit")
        }
        let amountMsat = amountSats * 1000
        
        let recipientName = NostrService.shared.profiles[notePubkey]?.bestName ?? String(notePubkey.prefix(8))
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
            let relayList = Self.receiptRelays(me: NostrService.shared.activeHexPubkey, recipient: notePubkey)

            var tags: [[String]] = [
                ["p", notePubkey],
                ["relays"] + relayList,
                ["amount", String(amountMsat)]
            ]
            
            if !noteId.isEmpty {
                tags.append(["e", noteId])
            }

            if let addressTag, !addressTag.isEmpty {
                tags.append(["a", addressTag, LiveChat.streamRelay])
            }
            
            // Add lnurl tag — strip internal sentinel prefix if present
            let lnurlTag = lud16.lowercased().hasPrefix("lnurl:") ? String(lud16.dropFirst(6)) : lud16
            tags.append(["lnurl", lnurlTag])
            
            guard let signedZapReq = await NostrService.shared.signEventAsync(kind: 9734, content: message, tags: tags) else {
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
            
            // 4. Pay via NWC
            do {
                let preimage = try await NWCService.payInvoice(bolt11: invoice)
                RelayProcessManager.shared.addLog("Zap: Successfully paid! Preimage: \(preimage)", level: "INFO")
                ZapNotificationManager.shared.markSuccess(id: notifId)
            } catch {
                RelayProcessManager.shared.addLog("Zap: NWC Payment failed: \(error.localizedDescription)", level: "ERROR")
                throw ZapError.paymentFailed(error.localizedDescription)
            }
        } catch {
            ZapNotificationManager.shared.markFailed(id: notifId, message: error.localizedDescription)
            throw error
        }
    }
}
