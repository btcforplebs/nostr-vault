import SwiftUI
import CoreImage.CIFilterBuiltins

struct WalletLightningTab: View {
    @EnvironmentObject var nostrService: NostrService
    @EnvironmentObject var configService: ConfigService

    // Balance
    @State private var balanceSats: Int? = nil
    @State private var isLoadingBalance = false
    @State private var balanceError: String? = nil

    // Send
    @State private var invoiceToPay: String = ""
    @State private var isSending = false
    @State private var sendResult: String? = nil
    @State private var sendError: String? = nil

    // Receive
    @State private var receiveAmountSats: String = ""
    @State private var receiveDescription: String = ""
    @State private var isCreatingInvoice = false
    @State private var generatedInvoice: String? = nil
    @State private var receiveError: String? = nil
    @State private var copiedInvoice = false

    // Lightning address
    @State private var copiedLnAddress = false

    private var lightningAddress: String? {
        let pubkey = nostrService.activeHexPubkey
        return nostrService.profiles[pubkey]?.lud16
    }

    private var hasNWC: Bool {
        !configService.config.nwcURI.isEmpty
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                if !hasNWC {
                    nwcNotConfiguredCard
                } else {
                    // MARK: - Balance
                    balanceCard

                    // MARK: - Lightning Address
                    if let lnAddr = lightningAddress, !lnAddr.isEmpty {
                        lightningAddressCard(lnAddr)
                    }

                    // MARK: - Receive
                    receiveCard

                    // MARK: - Send
                    sendCard
                }

                Spacer(minLength: 20)
            }
            .padding(.top, 12)
        }
        .onAppear {
            if hasNWC { fetchBalance() }
        }
    }

    // MARK: - NWC Not Configured

    private var nwcNotConfiguredCard: some View {
        VStack(spacing: 12) {
            Image(systemName: "bolt.slash.fill")
                .font(.system(size: 32))
                .foregroundColor(.secondary)
            Text("No Wallet Connected")
                .font(.system(size: 16, weight: .semibold))
                .foregroundColor(.primary)
            Text("Add a Nostr Wallet Connect URI in Settings to enable Lightning payments.")
                .font(.system(size: 13))
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(24)
        .frame(maxWidth: .infinity)
        .background(Color.platformControlBackground.opacity(0.6))
        .cornerRadius(12)
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color.platformSeparator.opacity(0.4), lineWidth: 1)
        )
        .padding(.horizontal, 16)
    }

    // MARK: - Balance Card

    private var balanceCard: some View {
        VStack(spacing: 8) {
            HStack {
                Image(systemName: "bolt.fill")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(.orange)
                Text("LIGHTNING BALANCE")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundColor(.secondary)
                Spacer()
                if isLoadingBalance {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Button(action: { fetchBalance() }) {
                        Image(systemName: "arrow.clockwise")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundColor(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }

            if let error = balanceError {
                Text(error)
                    .font(.caption)
                    .foregroundColor(.red)
            } else if let balance = balanceSats {
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text(formatSats(balance))
                        .font(.system(size: 28, weight: .bold, design: .rounded))
                        .foregroundColor(.primary)
                    Text("sats")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundColor(.secondary)
                    Spacer()
                }
            } else if !isLoadingBalance {
                HStack {
                    Text("--")
                        .font(.system(size: 28, weight: .bold, design: .rounded))
                        .foregroundColor(.secondary)
                    Spacer()
                }
            }
        }
        .padding(16)
        .background(Color.platformControlBackground.opacity(0.6))
        .cornerRadius(12)
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color.platformSeparator.opacity(0.4), lineWidth: 1)
        )
        .padding(.horizontal, 16)
    }

    // MARK: - Lightning Address Card

    private func lightningAddressCard(_ address: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "bolt.fill")
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(.orange)
            Text(address)
                .font(.system(.caption, design: .monospaced))
                .foregroundColor(.secondary)
                .lineLimit(1)
            Spacer()
            Button(action: {
                PlatformClipboard.copy(address)
                copiedLnAddress = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 2) { copiedLnAddress = false }
            }) {
                Image(systemName: copiedLnAddress ? "checkmark" : "doc.on.doc")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(copiedLnAddress ? .green : .secondary)
            }
            .buttonStyle(.plain)
        }
        .padding(12)
        .background(Color.platformControlBackground.opacity(0.6))
        .cornerRadius(12)
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color.platformSeparator.opacity(0.4), lineWidth: 1)
        )
        .padding(.horizontal, 16)
    }

    // MARK: - Receive Card

    private var receiveCard: some View {
        VStack(spacing: 12) {
            HStack {
                Image(systemName: "arrow.down.circle.fill")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(.green)
                Text("RECEIVE")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundColor(.secondary)
                Spacer()
            }

            HStack(spacing: 8) {
                TextField("Amount (sats)", text: $receiveAmountSats)
                    .font(.system(size: 14, design: .monospaced))
                    #if os(iOS)
                    .keyboardType(.numberPad)
                    #endif
                    .textFieldStyle(.roundedBorder)

                TextField("Description (optional)", text: $receiveDescription)
                    .font(.system(size: 14))
                    .textFieldStyle(.roundedBorder)
            }

            Button(action: { createInvoice() }) {
                HStack(spacing: 6) {
                    if isCreatingInvoice {
                        ProgressView()
                            .controlSize(.small)
                    }
                    Text("Create Invoice")
                        .font(.system(size: 14, weight: .semibold))
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
            }
            .buttonStyle(.bordered)
            .tint(.green)
            .disabled(receiveAmountSats.isEmpty || isCreatingInvoice)

            if let error = receiveError {
                Text(error)
                    .font(.caption)
                    .foregroundColor(.red)
            }

            if let invoice = generatedInvoice {
                invoiceResultView(invoice)
            }
        }
        .padding(16)
        .background(Color.platformControlBackground.opacity(0.6))
        .cornerRadius(12)
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color.platformSeparator.opacity(0.4), lineWidth: 1)
        )
        .padding(.horizontal, 16)
    }

    // MARK: - Generated Invoice Display

    private func invoiceResultView(_ invoice: String) -> some View {
        VStack(spacing: 10) {
            if let qrImage = generateQRCode(from: invoice.uppercased()) {
                HStack {
                    Spacer()
                    Image(platformImage: qrImage)
                        .interpolation(.none)
                        .resizable()
                        .scaledToFit()
                        .frame(width: 140, height: 140)
                        .cornerRadius(8)
                    Spacer()
                }
            }

            Text(invoice)
                .font(.system(size: 10, design: .monospaced))
                .foregroundColor(.secondary)
                .lineLimit(4)
                .textSelection(.enabled)

            Button(action: {
                PlatformClipboard.copy(invoice)
                copiedInvoice = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 2) { copiedInvoice = false }
            }) {
                Label(
                    copiedInvoice ? "Copied!" : "Copy Invoice",
                    systemImage: copiedInvoice ? "checkmark" : "doc.on.doc"
                )
                .font(.system(size: 13, weight: .medium))
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .tint(.green)
        }
        .padding(.top, 8)
    }

    // MARK: - Send Card

    private var sendCard: some View {
        VStack(spacing: 12) {
            HStack {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(.orange)
                Text("SEND")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundColor(.secondary)
                Spacer()
            }

            TextField("Paste bolt11 invoice...", text: $invoiceToPay)
                .font(.system(size: 13, design: .monospaced))
                .textFieldStyle(.roundedBorder)
                .lineLimit(3)

            Button(action: { payInvoice() }) {
                HStack(spacing: 6) {
                    if isSending {
                        ProgressView()
                            .controlSize(.small)
                    }
                    Text("Pay Invoice")
                        .font(.system(size: 14, weight: .semibold))
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
            }
            .buttonStyle(.bordered)
            .tint(.orange)
            .disabled(invoiceToPay.isEmpty || isSending)

            if let error = sendError {
                Text(error)
                    .font(.caption)
                    .foregroundColor(.red)
            }

            if let result = sendResult {
                HStack(spacing: 6) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundColor(.green)
                    Text(result)
                        .font(.caption)
                        .foregroundColor(.green)
                }
            }
        }
        .padding(16)
        .background(Color.platformControlBackground.opacity(0.6))
        .cornerRadius(12)
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color.platformSeparator.opacity(0.4), lineWidth: 1)
        )
        .padding(.horizontal, 16)
    }

    // MARK: - Actions

    private func fetchBalance() {
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

    private func payInvoice() {
        let invoice = invoiceToPay.trimmingCharacters(in: .whitespacesAndNewlines)
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
                }
            } catch {
                await MainActor.run {
                    sendError = error.localizedDescription
                    isSending = false
                }
            }
        }
    }

    private func createInvoice() {
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

    private func formatSats(_ sats: Int) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.groupingSeparator = ","
        formatter.usesGroupingSeparator = true
        return formatter.string(from: NSNumber(value: sats)) ?? "\(sats)"
    }

    private func generateQRCode(from string: String) -> PlatformImage? {
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
