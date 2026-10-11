import SwiftUI
import CoreImage.CIFilterBuiltins

extension WalletLightningTab {
    // MARK: - Send Card

    var sendCard: some View {
        VStack(spacing: 12) {
            HStack {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.appSystem(size: 14, weight: .semibold))
                    .foregroundColor(.orange)
                Text("SEND")
                    .font(.appSystem(size: 12, weight: .bold))
                    .foregroundColor(.secondary)
                Spacer()
            }

            TextField("Invoice, lightning address or LNURL", text: $invoiceToPay)
                .font(.appSystem(size: 13, design: .monospaced))
                .textFieldStyle(.roundedBorder)
                .lineLimit(3)
                .autocorrectionDisabled()
                #if os(iOS)
                .textInputAutocapitalization(.never)
                .keyboardType(.asciiCapable)
                #endif

            switch payTarget {
            case .none:
                if !invoiceToPay.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Text("Not something this wallet can pay. Paste a lightning invoice, a lightning address (name@domain.com) or an LNURL.")
                        .font(.appCaption)
                        .foregroundColor(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            case .invoice:
                invoiceAmountLine
                payInvoiceButton
            case .address, .lnurl, .lnurlURL:
                lnurlSection
            }

            if let error = sendError {
                Text(error)
                    .font(.appCaption)
                    .foregroundColor(.red)
            }

            if let result = sendResult {
                HStack(spacing: 6) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundColor(.green)
                    Text(result)
                        .font(.appCaption)
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

    var payTarget: LightningPayTarget? {
        LightningPayTarget.parse(invoiceToPay)
    }

    /// The bolt11 in the box with any `lightning:` / BIP21 wrapping removed —
    /// what is shown, confirmed and sent to the wallet.
    var parsedInvoice: String {
        if case .invoice(let s) = payTarget { return s }
        return invoiceToPay.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var payInvoiceButton: some View {
        VStack(spacing: 12) {
            Button(action: { showingPayConfirm = true }) {
                HStack(spacing: 6) {
                    if isSending {
                        ProgressView()
                            .controlSize(.small)
                    }
                    Text("Pay Invoice")
                        .font(.appSystem(size: 14, weight: .semibold))
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
            }
            .buttonStyle(.bordered)
            .tint(.orange)
            .disabled(invoiceToPay.isEmpty || isSending)
            .confirmDestructive(
                "Pay Invoice",
                isPresented: $showingPayConfirm,
                consequence: payConfirmationMessage,
                confirmTitle: "Pay",
                action: payInvoice
            )
        }
    }
}
