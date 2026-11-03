import SwiftUI

/// Review a shared invoice, lightning address or LNURL, then pay it (or zap,
/// when the address is the shared npub's own). The amount is always on the
/// card and in the confirm; nothing leaves the wallet before that confirm.
struct PayReviewView: View {
    let intent: NVShareIntent
    let close: () -> Void

    @ObservedObject private var config = ConfigService.shared
    @State private var resolved: LNURLService.LNURLPayResponse?
    @State private var host = ""
    @State private var resolving = false
    @State private var amountText = ""
    @State private var comment = ""
    @State private var asZap = false
    @State private var confirming = false
    @State private var paying = false
    @State private var done: String?
    @State private var error: String?

    private var target: PayShareTarget? { PayShareHandler.target(of: intent) }
    private var npub: String { PayShareHandler.account(for: intent) }
    private var hasWallet: Bool { !config.config.nwcURI.isEmpty }
    private var attempt: PayShareAttempts.State? { PayShareAttempts.state(intent.id) }

    var body: some View {
        Form {
            if let target {
                switch target.kind {
                case .invoice: invoiceSection(target.token)
                case .address, .lnurl: lnurlSection(target)
                }
            } else {
                Section { Text("There's nothing here Nostr Vault can pay.").foregroundStyle(.secondary) }
            }
            DMShareAccountRow(npub: npub, title: "Paying from the wallet of")
            if !hasWallet {
                Section { Text("Connect a wallet in the Wallet tab first.").font(.footnote).foregroundStyle(.secondary) }
            }
            if let error { Section { Text(error).foregroundStyle(.red).font(.footnote) } }
            if let done {
                Section {
                    Label(done, systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                    Button("Done", action: close)
                }
            } else if target != nil {
                payButton
            }
        }
        .task { await resolveIfNeeded() }
        .alert("Send this payment?", isPresented: $confirming) {
            Button("Cancel", role: .cancel) {}
            Button("Pay") { pay() }
        } message: {
            Text(confirmation)
        }
    }

    // MARK: Invoice

    @ViewBuilder
    private func invoiceSection(_ invoice: String) -> some View {
        if let details = Bolt11.details(invoice) {
            Section("Invoice") {
                Text(Self.satsText(details.amount)).font(.title2.bold())
                if let memo = details.memo { Text(memo) }
                TimelineView(.periodic(from: .now, by: 30)) { context in
                    Text(details.isExpired(at: context.date) ? "Expired" : "Expires \(details.expiresAt.formatted(.relative(presentation: .named)))")
                        .font(.footnote)
                        .foregroundStyle(details.isExpired(at: context.date) ? .red : .secondary)
                }
            }
        } else {
            Section { Text("This invoice can't be read, so it can't be paid here.").foregroundStyle(.secondary) }
        }
    }

    private static func satsText(_ amount: Bolt11.Amount) -> String {
        if case .sats(let sats) = amount { return "\(sats.formatted()) sats" }
        return "No amount"
    }

    // MARK: Address / LNURL

    @ViewBuilder
    private func lnurlSection(_ target: PayShareTarget) -> some View {
        Section("To") {
            Text(target.kind == .address ? target.token : (host.isEmpty ? "LNURL" : host))
                .lineLimit(2).truncationMode(.middle)
            if resolving { ProgressView() }
        }
        if let pay = resolved {
            let range = LNURLAmountRange(minMsat: pay.minSendable, maxMsat: pay.maxSendable)
            Section {
                TextField("Amount in sats", text: $amountText)
                    #if os(iOS)
                    .keyboardType(.numberPad)
                    #endif
                if (pay.commentAllowed ?? 0) > 0 || zapOffered(pay) {
                    TextField("Note (optional)", text: $comment, axis: .vertical).lineLimit(1...3)
                }
                if zapOffered(pay), let hex = recipientHex {
                    Toggle("Send as a public zap to \(NostrService.shared.profiles[hex]?.bestName ?? "them")", isOn: $asZap)
                }
            } header: {
                Text("Amount")
            } footer: {
                Text(range.isFixed ? "This service takes exactly \(range.minSats.formatted()) sats."
                     : "\(range.minSats.formatted())–\(range.maxSats.formatted()) sats." + (asZap ? " A zap is public." : ""))
            }
        }
    }

    private var recipientHex: String? {
        target?.recipientNpub.flatMap { Bech32.decode($0) }.map(\.hexString)
    }

    private func zapOffered(_ pay: LNURLService.LNURLPayResponse) -> Bool {
        guard let target, let hex = recipientHex, pay.allowsNostr == true, pay.nostrPubkey != nil else { return false }
        return PayShareTarget.canZap(target, profileLightningAddress: NostrService.shared.profiles[hex]?.lud16)
    }

    private func resolveIfNeeded() async {
        guard let target, target.kind != .invoice, resolved == nil, !resolving,
              let payTarget = LightningPayTarget.parse(target.token) else { return }
        resolving = true
        defer { resolving = false }
        do {
            switch try await LNURLService.resolve(payTarget) {
            case .pay(let pay, let h):
                resolved = pay
                host = h
                let range = LNURLAmountRange(minMsat: pay.minSendable, maxMsat: pay.maxSendable)
                if range.isFixed { amountText = String(range.minSats) }
            case .withdraw:
                error = "This link pays you rather than asking for a payment. Open it from the Wallet tab."
            }
        } catch {
            self.error = error.localizedDescription
        }
    }

    // MARK: Pay

    private var lnurlCheck: LNURLAmountRange.Check? {
        guard let pay = resolved else { return nil }
        return LNURLAmountRange(minMsat: pay.minSendable, maxMsat: pay.maxSendable).check(sats: Int(amountText))
    }

    private var canPay: Bool {
        guard let target, hasWallet, !paying, DMShareAccountRow.isReady(npub) else { return false }
        switch target.kind {
        case .invoice:
            guard attempt != .paid, let d = Bolt11.details(target.token), case .sats = d.amount else { return false }
            return !d.isExpired()
        case .address, .lnurl:
            guard attempt == nil, case .ok = lnurlCheck else { return false }
            return true
        }
    }

    private var payButton: some View {
        Section {
            Button { confirming = true } label: {
                HStack {
                    Spacer()
                    if paying { ProgressView() } else { Text(payTitle).font(.headline) }
                    Spacer()
                }
            }
            .disabled(!canPay)
        } footer: {
            if attempt != nil, target?.kind != .invoice {
                Text(PayShareHandler.PayError.alreadyTried.localizedDescription)
            } else {
                Text("Lightning payments can't be reversed.")
            }
        }
    }

    private var payTitle: String {
        if target?.kind == .invoice, let d = target.flatMap({ Bolt11.details($0.token) }) {
            return "Pay \(Self.satsText(d.amount))"
        }
        if case .ok(let msat) = lnurlCheck { return (asZap ? "Zap " : "Pay ") + "\((msat / 1000).formatted()) sats" }
        return "Pay"
    }

    /// The last thing read before the sats leave, so it repeats the number.
    private var confirmation: String {
        guard let target else { return "" }
        switch target.kind {
        case .invoice:
            let d = Bolt11.details(target.token)
            let memo = d?.memo.map { " for “\($0)”" } ?? ""
            return "This sends \(d.map { Self.satsText($0.amount) } ?? "")\(memo) from your wallet. Lightning payments can't be reversed."
        case .address, .lnurl:
            guard case .ok(let msat) = lnurlCheck else { return "" }
            let to = target.kind == .address ? target.token : host
            return "This sends \((msat / 1000).formatted()) sats to \(to)\(asZap ? " as a public zap" : ""). Lightning payments can't be reversed."
        }
    }

    private func pay() {
        guard canPay, let target else { return }
        paying = true
        error = nil
        let check = lnurlCheck
        let zapTo = asZap ? recipientHex : nil
        let note = comment.trimmingCharacters(in: .whitespacesAndNewlines)
        Task {
            do {
                switch target.kind {
                case .invoice:
                    try await PayShareHandler.payInvoice(target.token, intent: intent)
                    done = "Paid."
                case .address, .lnurl:
                    guard let pay = resolved, case .ok(let msat)? = check else { paying = false; return }
                    try await PayShareHandler.payLNURL(pay, token: target.token, msat: msat, comment: note,
                                                       zapTo: zapTo, host: host, intent: intent)
                    done = "Sent \((msat / 1000).formatted()) sats."
                }
            } catch NWCService.NWCError.notConnected {
                error = "Your wallet didn't confirm in time. The payment may still go through, so check History before paying again."
            } catch {
                self.error = error.localizedDescription
            }
            paying = false
        }
    }
}
