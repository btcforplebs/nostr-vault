import SwiftUI

/// A Lightning invoice someone pasted into a note, drawn as something you can
/// read and pay: what it costs, what it is for, and whether it has lapsed.
/// Pays through the connected wallet (NWC), the same path as a zap.
struct LightningInvoiceCard: View {
    let match: NoteInvoices.Match

    private enum PayState: Equatable { case idle, paying, paid, failed(String) }
    @State private var state: PayState = .idle
    @State private var confirming = false
    @State private var copied = false

    private var details: Bolt11.Details { match.details }
    private var hasWallet: Bool { !ConfigService.shared.config.nwcURI.isEmpty }

    var body: some View {
        // Re-read every 30 s so an invoice that lapses while on screen says so.
        TimelineView(.periodic(from: .now, by: 30)) { context in
            card(expired: details.isExpired(at: context.date), now: context.date)
        }
        .alert("Pay this invoice?", isPresented: $confirming) {
            Button("Cancel", role: .cancel) {}
            Button("Pay") { pay() }
        } message: {
            Text(confirmationMessage)
        }
    }

    private func card(expired: Bool, now: Date) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: "bolt.fill")
                    .font(.appSystem(size: 15, weight: .semibold))
                    .foregroundColor(expired ? .secondary : .orange)
                Text(amountText)
                    .font(.appSystem(size: 22, weight: .bold, design: .rounded))
                    .foregroundColor(expired ? .secondary : .primary)
                    .strikethrough(expired)
                Spacer(minLength: 8)
                Text(statusText(expired: expired, now: now))
                    .font(.appSystem(size: 12, weight: .medium))
                    .foregroundColor(expired ? .red.opacity(0.85) : .secondary)
            }

            if let memo = details.memo {
                Text(memo)
                    .font(.appSystem(size: 14))
                    .foregroundColor(.primary.opacity(expired ? 0.5 : 0.9))
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack(spacing: 8) {
                payButton(expired: expired)
                Button {
                    PlatformClipboard.copy(match.invoice)
                    copied = true
                    Task { try? await Task.sleep(for: .seconds(1.5)); copied = false }
                } label: {
                    Label(copied ? "Copied" : "Copy", systemImage: copied ? "checkmark" : "doc.on.doc")
                        .font(.appSystem(size: 14, weight: .medium))
                        .frame(minHeight: 36)
                        .padding(.horizontal, 12)
                        .background(Color.primary.opacity(0.08))
                        .clipShape(Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(copied ? "Invoice copied" : "Copy invoice")
            }

            if let footnote = footnote(expired: expired) {
                Text(footnote)
                    .font(.appSystem(size: 12))
                    .foregroundColor(footnoteIsError ? .red.opacity(0.85) : .secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.platformTertiaryGroupedBackground)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(Color.orange.opacity(expired ? 0.12 : 0.35), lineWidth: 1)
        )
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder
    private func payButton(expired: Bool) -> some View {
        let enabled = hasWallet && !expired && (state == .idle || isFailed)
        Button { confirming = true } label: {
            HStack(spacing: 6) {
                if state == .paying {
                    ProgressView().controlSize(.small).tint(.black)
                } else {
                    Image(systemName: state == .paid ? "checkmark" : "bolt.fill")
                }
                Text(payLabel(expired: expired))
            }
            .font(.appSystem(size: 14, weight: .semibold))
            .foregroundColor(enabled || state == .paid ? .black : .secondary)
            .frame(maxWidth: .infinity, minHeight: 36)
            .background(enabled || state == .paid ? Color.orange : Color.primary.opacity(0.08))
            .clipShape(Capsule())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
    }

    // MARK: - Words

    private var amountText: String {
        if case .sats(let sats) = details.amount { return "\(sats.formatted()) sats" }
        return "Any amount"
    }

    private func statusText(expired: Bool, now: Date) -> String {
        if state == .paid { return "Paid" }
        if expired { return "Expired" }
        let left = details.expiresAt.timeIntervalSince(now)
        if left < 60 { return "Expires in under a minute" }
        let f = DateComponentsFormatter()
        f.unitsStyle = .short
        f.maximumUnitCount = 1
        f.allowedUnits = [.day, .hour, .minute]
        return "Expires in \(f.string(from: left) ?? "")"
    }

    private func payLabel(expired: Bool) -> String {
        switch state {
        case .paying: return "Paying…"
        case .paid: return "Paid"
        case .failed: return "Try again"
        case .idle: return expired ? "Expired" : "Pay"
        }
    }

    private var isFailed: Bool { if case .failed = state { return true }; return false }
    private var footnoteIsError: Bool { isFailed }

    private func footnote(expired: Bool) -> String? {
        if case .failed(let message) = state { return message }
        if state == .paid || expired { return nil }
        if !hasWallet { return "Connect a wallet in the Wallet tab to pay invoices here." }
        if details.amount == .unspecified {
            return "This invoice names no amount — your wallet decides, and may refuse it."
        }
        return nil
    }

    /// The last surface before the sats leave, so it repeats the number.
    private var confirmationMessage: String {
        let memo = details.memo.map { " for “\($0)”" } ?? ""
        switch details.amount {
        case .sats(let sats):
            return "This sends \(sats.formatted()) sats\(memo) from your wallet. Lightning payments cannot be reversed."
        default:
            return "This invoice\(memo) names no amount, so your wallet decides what to send — and it may refuse it outright. Lightning payments cannot be reversed."
        }
    }

    private func pay() {
        state = .paying
        let invoice = match.invoice
        Task {
            do {
                _ = try await NWCService.payInvoice(bolt11: invoice)
                await MainActor.run { state = .paid }
            } catch {
                await MainActor.run { state = .failed(error.localizedDescription) }
            }
        }
    }
}
