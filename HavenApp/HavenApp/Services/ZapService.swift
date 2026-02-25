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
    
    /// Executes a full Zap flow: LNURL -> Zap Request -> Invoice -> NWC Payment
    func zapNote(noteId: String, notePubkey: String, lud16: String, amountSats: Int? = nil, message: String = "Zap from Haven") async throws {
        let amountSats = amountSats ?? (ConfigService.shared.config.defaultZapAmount / 1000)
        let amountMsat = amountSats * 1000
        
        RelayProcessManager.shared.addLog("Zap: Starting zap for \(lud16) (\(amountSats) sats)", level: "INFO")
        
        // 1. Resolve LNURL
        let lnurlResponse: LNURLService.LNURLPayResponse
        do {
            lnurlResponse = try await LNURLService.resolveAddress(lud16)
        } catch {
            RelayProcessManager.shared.addLog("Zap: LNURL resolution failed: \(error.localizedDescription)", level: "ERROR")
            throw ZapError.lnurlResolutionFailed
        }
        
        // 2. Build Zap Request (Kind 9734)
        var tags: [[String]] = [
            ["p", notePubkey],
            ["relays", ConfigService.shared.config.nostrURL], // Use Haven's own relay for receipts
            ["amount", String(amountMsat)]
        ]
        
        if !noteId.isEmpty {
            tags.append(["e", noteId])
        }
        
        // Add lnurl tag if available from resolution
        tags.append(["lnurl", lud16])
        
        // Sign using the account's NostrService
        // Note: In a real app, you'd use the current user's NostrService singleton
        guard let signedZapReq = NostrService.shared.signEvent(kind: 9734, content: message, tags: tags) else {
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
        } catch {
            RelayProcessManager.shared.addLog("Zap: NWC Payment failed: \(error.localizedDescription)", level: "ERROR")
            throw ZapError.paymentFailed(error.localizedDescription)
        }
    }
}
