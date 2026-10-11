import SwiftUI
import CoreImage.CIFilterBuiltins

extension WalletLightningTab {
    // MARK: - Actions

    func fetchBalance() {
        isLoadingBalance = true
        balanceError = nil
        Task {
            do {
                let msats = try await NWCService.getBalance()
                await MainActor.run {
                    balanceSats = msats / 1000
                    isLoadingBalance = false
                }
            } catch {
                await MainActor.run {
                    balanceError = error.localizedDescription
                    isLoadingBalance = false
                }
            }
        }
    }

    /// What you are about to spend.
    ///
    /// The button pays whatever is in the box, and a bolt11 invoice states its
    /// amount in a form nobody can read at a glance, so without this the sats
    /// leave before you ever see the number.
    ///
    /// Reading only — an invoice this app cannot parse is still payable, since
    /// the wallet on the other end is the authority on that, not us.
    @ViewBuilder
    var invoiceAmountLine: some View {
        switch Bolt11.amount(parsedInvoice) {
        case .sats(let sats):
            Text("Paying \(sats.formatted()) sats")
                .font(.appSystem(size: 13, weight: .semibold))
                .foregroundColor(.orange)
                .frame(maxWidth: .infinity, alignment: .leading)
        case .unspecified:
            Text("This invoice names no amount, and Nostr Vault cannot set one — your wallet will probably refuse it.")
                .font(.appCaption)
                .foregroundColor(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
        case .unreadable:
            Text("Not an invoice this app can read. Check it before you pay.")
                .font(.appCaption)
                .foregroundColor(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// The stakes, for the confirmation. `invoiceAmountLine` already shows this
    /// next to the field, but the alert is the last surface before the sats
    /// leave, so it repeats the number rather than assuming you read the line.
    var payConfirmationMessage: String {
        switch Bolt11.amount(parsedInvoice) {
        case .sats(let sats):
            return "This sends \(sats.formatted()) sats from your wallet. Lightning payments cannot be reversed."
        case .unspecified:
            return "This invoice names no amount, so your wallet decides what to send — and it may refuse it outright. Lightning payments cannot be reversed."
        case .unreadable:
            return "Nostr Vault cannot read this invoice, so it cannot tell you what it will cost. Your wallet will pay whatever it says. Lightning payments cannot be reversed."
        }
    }

    func payInvoice() {
        let invoice = parsedInvoice
        guard !invoice.isEmpty else { return }
        isSending = true
        sendError = nil
        sendResult = nil
        Task {
            do {
                let preimage = try await NWCService.payInvoice(bolt11: invoice)
                await MainActor.run {
                    sendResult = "Payment sent! Preimage: \(preimage.prefix(16))..."
                    invoiceToPay = ""
                    isSending = false
                    fetchBalance()
                    loadHistory(reset: true)
                }
            } catch {
                await MainActor.run {
                    sendError = error.localizedDescription
                    isSending = false
                }
            }
        }
    }

    func createInvoice() {
        guard let sats = Int(receiveAmountSats), sats > 0 else {
            receiveError = "Enter a valid amount in sats."
            return
        }
        let msats = sats * 1000
        let desc = receiveDescription.isEmpty ? nil : receiveDescription
        isCreatingInvoice = true
        receiveError = nil
        generatedInvoice = nil
        Task {
            do {
                let bolt11 = try await NWCService.makeInvoice(amountMsats: msats, description: desc)
                await MainActor.run {
                    generatedInvoice = bolt11
                    isCreatingInvoice = false
                }
            } catch {
                await MainActor.run {
                    receiveError = error.localizedDescription
                    isCreatingInvoice = false
                }
            }
        }
    }

    // MARK: - Helpers

    func formatSats(_ sats: Int) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.groupingSeparator = ","
        formatter.usesGroupingSeparator = true
        return formatter.string(from: NSNumber(value: sats)) ?? "\(sats)"
    }

    func generateQRCode(from string: String) -> PlatformImage? {
        guard let data = string.data(using: .utf8),
              let filter = CIFilter(name: "CIQRCodeGenerator") else { return nil }
        filter.setValue(data, forKey: "inputMessage")
        filter.setValue("M", forKey: "inputCorrectionLevel")
        guard let output = filter.outputImage else { return nil }
        let scaled = output.transformed(by: CGAffineTransform(scaleX: 10, y: 10))
        let context = CIContext()
        guard let cgImage = context.createCGImage(scaled, from: scaled.extent) else { return nil }
        #if os(iOS)
        return UIImage(cgImage: cgImage)
        #else
        return NSImage(cgImage: cgImage, size: scaled.extent.size)
        #endif
    }
}
