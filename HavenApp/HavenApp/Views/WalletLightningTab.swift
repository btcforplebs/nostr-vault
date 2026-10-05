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
    @State private var showingPayConfirm = false

    // Receive
    @State private var receiveAmountSats: String = ""
    @State private var receiveDescription: String = ""
    @State private var isCreatingInvoice = false
    @State private var generatedInvoice: String? = nil
    @State private var receiveError: String? = nil
    @State private var copiedInvoice = false

    // Lightning address
    @State private var copiedLnAddress = false

    // Send to a lightning address / LNURL
    @State private var resolved: LNURLService.Resolved? = nil
    @State private var isResolving = false
    @State private var resolveError: String? = nil
    @State private var lnurlAmountSats: String = ""
    @State private var lnurlComment: String = ""
    @State private var showingLNURLPayConfirm = false
    @State private var isWithdrawing = false

    // History
    @State private var transactions: [WalletTransaction] = []
    @State private var isLoadingHistory = false
    @State private var historyError: String? = nil
    @State private var historyUnsupported = false
    @State private var canLoadMoreHistory = false
    @State private var historyRefreshPending = false
    @State private var zapDetails: [String: ZapDetail] = [:]
    @State private var zapPosts: [String: FeedNote] = [:]
    private static let historyPageSize = 20

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

                    // MARK: - History
                    historyCard
                }

                Spacer(minLength: 20)
            }
            .padding(.top, 12)
        }
        .onAppear {
            if hasNWC {
                fetchBalance()
                loadHistory(reset: true)
            }
        }
        .task(id: invoiceToPay) { await resolveLNURLIfNeeded() }
        .navigationDestination(for: FeedNote.self) { note in
            NoteDetailView(note: note)
        }
    }

    // MARK: - NWC Not Configured

    private var nwcNotConfiguredCard: some View {
        VStack(spacing: 12) {
            Image(systemName: "bolt.slash.fill")
                .font(.appSystem(size: 32))
                .foregroundColor(.secondary)
            Text("No Wallet Connected")
                .font(.appSystem(size: 16, weight: .semibold))
                .foregroundColor(.primary)
            Text("Add a Nostr Wallet Connect URI in Settings to enable Lightning payments.")
                .font(.appSystem(size: 13))
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
                    .font(.appSystem(size: 14, weight: .semibold))
                    .foregroundColor(.orange)
                Text("LIGHTNING BALANCE")
                    .font(.appSystem(size: 12, weight: .bold))
                    .foregroundColor(.secondary)
                Spacer()
                if isLoadingBalance {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Button(action: { fetchBalance() }) {
                        Image(systemName: "arrow.clockwise")
                            .font(.appSystem(size: 12, weight: .semibold))
                            .foregroundColor(.secondary)
                            .frame(width: 28, height: 28)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("Refresh")
                }
            }

            if let error = balanceError {
                Text(error)
                    .font(.appCaption)
                    .foregroundColor(.red)
            } else if let balance = balanceSats {
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text(formatSats(balance))
                        .font(.appSystem(size: 28, weight: .bold, design: .rounded))
                        .foregroundColor(.primary)
                    Text("sats")
                        .font(.appSystem(size: 14, weight: .medium))
                        .foregroundColor(.secondary)
                    Spacer()
                }
            } else if !isLoadingBalance {
                HStack {
                    Text("--")
                        .font(.appSystem(size: 28, weight: .bold, design: .rounded))
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
                .font(.appSystem(size: 14, weight: .semibold))
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
                    .font(.appSystem(size: 12, weight: .semibold))
                    .foregroundColor(copiedLnAddress ? .green : .secondary)
                    .frame(width: 28, height: 28)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Copy")
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
                    .font(.appSystem(size: 14, weight: .semibold))
                    .foregroundColor(.green)
                Text("RECEIVE")
                    .font(.appSystem(size: 12, weight: .bold))
                    .foregroundColor(.secondary)
                Spacer()
            }

            HStack(spacing: 8) {
                TextField("Amount (sats)", text: $receiveAmountSats)
                    .font(.appSystem(size: 14, design: .monospaced))
                    #if os(iOS)
                    .keyboardType(.numberPad)
                    #endif
                    .textFieldStyle(.roundedBorder)

                TextField("Description (optional)", text: $receiveDescription)
                    .font(.appSystem(size: 14))
                    .textFieldStyle(.roundedBorder)
            }

            Button(action: { createInvoice() }) {
                HStack(spacing: 6) {
                    if isCreatingInvoice {
                        ProgressView()
                            .controlSize(.small)
                    }
                    Text("Create Invoice")
                        .font(.appSystem(size: 14, weight: .semibold))
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
            }
            .buttonStyle(.bordered)
            .tint(.green)
            .disabled(receiveAmountSats.isEmpty || isCreatingInvoice)

            if let error = receiveError {
                Text(error)
                    .font(.appCaption)
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
                .font(.appSystem(size: 10, design: .monospaced))
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
                .font(.appSystem(size: 13, weight: .medium))
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

    private var payTarget: LightningPayTarget? {
        LightningPayTarget.parse(invoiceToPay)
    }

    /// The bolt11 in the box with any `lightning:` / BIP21 wrapping removed —
    /// what is shown, confirmed and sent to the wallet.
    private var parsedInvoice: String {
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

    // MARK: - Lightning address / LNURL

    /// Who the money goes to (or comes from), in the words the user typed.
    private var counterpartyName: String {
        if case .address(let a) = payTarget { return a }
        switch resolved {
        case .pay(_, let host), .withdraw(_, let host): return host
        case nil: return "this service"
        }
    }

    @ViewBuilder
    private var lnurlSection: some View {
        if isResolving {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Looking it up…")
                    .font(.appCaption)
                    .foregroundColor(.secondary)
                Spacer()
            }
        } else if let resolveError {
            Text(resolveError)
                .font(.appCaption)
                .foregroundColor(.red)
                .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            switch resolved {
            case .pay(let pay, _):
                lnurlPayPanel(pay)
            case .withdraw(let withdraw, _):
                lnurlWithdrawPanel(withdraw)
            case nil:
                EmptyView()
            }
        }
    }

    private func lnurlPayPanel(_ pay: LNURLService.LNURLPayResponse) -> some View {
        let range = LNURLAmountRange(minMsat: pay.minSendable, maxMsat: pay.maxSendable)
        let note = Self.plainTextMetadata(pay.metadata)
        let commentLimit = pay.commentAllowed ?? 0
        let check = range.check(sats: Int(lnurlAmountSats))
        return VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text("To \(counterpartyName)")
                    .font(.appSystem(size: 13, weight: .semibold))
                if let note {
                    Text(note)
                        .font(.appCaption)
                        .foregroundColor(.secondary)
                        .lineLimit(3)
                }
            }

            if range.isFixed {
                Text("Amount: \(range.minSats.formatted()) sats")
                    .font(.appSystem(size: 13, weight: .semibold))
                    .foregroundColor(.orange)
            } else {
                TextField("Amount (sats)", text: $lnurlAmountSats)
                    .font(.appSystem(size: 14, design: .monospaced))
                    #if os(iOS)
                    .keyboardType(.numberPad)
                    #endif
                    .textFieldStyle(.roundedBorder)
                Text(rangeCaption(range, check: check))
                    .font(.appCaption)
                    .foregroundColor(isOutOfRange(check) ? .red : .secondary)
            }

            if commentLimit > 0 {
                TextField("Comment (optional)", text: $lnurlComment)
                    .font(.appSystem(size: 14))
                    .textFieldStyle(.roundedBorder)
                    .onChange(of: lnurlComment) { _, new in
                        if new.count > commentLimit { lnurlComment = String(new.prefix(commentLimit)) }
                    }
            }

            Button(action: { showingLNURLPayConfirm = true }) {
                HStack(spacing: 6) {
                    if isSending { ProgressView().controlSize(.small) }
                    Text(sendButtonTitle(check))
                        .font(.appSystem(size: 14, weight: .semibold))
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
            }
            .buttonStyle(.bordered)
            .tint(.orange)
            .disabled(isSending || !isOK(check))
            .confirmDestructive(
                "Send Payment",
                isPresented: $showingLNURLPayConfirm,
                consequence: lnurlPayConfirmation(check),
                confirmTitle: "Send",
                action: { payLNURL(pay, range: range) }
            )
        }
    }

    private func lnurlWithdrawPanel(_ w: LNURLService.LNURLWithdrawResponse) -> some View {
        let range = LNURLAmountRange(minMsat: w.minWithdrawable, maxMsat: w.maxWithdrawable)
        let check = range.check(sats: Int(lnurlAmountSats))
        return VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Receive from \(counterpartyName)")
                    .font(.appSystem(size: 13, weight: .semibold))
                if let d = w.defaultDescription, !d.isEmpty {
                    Text(d)
                        .font(.appCaption)
                        .foregroundColor(.secondary)
                        .lineLimit(3)
                }
            }
            if range.isFixed {
                Text("Amount: \(range.minSats.formatted()) sats")
                    .font(.appSystem(size: 13, weight: .semibold))
                    .foregroundColor(.green)
            } else {
                TextField("Amount (sats)", text: $lnurlAmountSats)
                    .font(.appSystem(size: 14, design: .monospaced))
                    #if os(iOS)
                    .keyboardType(.numberPad)
                    #endif
                    .textFieldStyle(.roundedBorder)
                Text(rangeCaption(range, check: check))
                    .font(.appCaption)
                    .foregroundColor(isOutOfRange(check) ? .red : .secondary)
            }
            Button(action: { withdrawLNURL(w, range: range) }) {
                HStack(spacing: 6) {
                    if isWithdrawing { ProgressView().controlSize(.small) }
                    Text("Receive")
                        .font(.appSystem(size: 14, weight: .semibold))
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
            }
            .buttonStyle(.bordered)
            .tint(.green)
            .disabled(isWithdrawing || !isOK(check))
        }
    }

    private func isOK(_ check: LNURLAmountRange.Check) -> Bool {
        if case .ok = check { return true }
        return false
    }

    private func isOutOfRange(_ check: LNURLAmountRange.Check) -> Bool {
        switch check {
        case .tooSmall, .tooLarge: return true
        default: return false
        }
    }

    private func rangeCaption(_ range: LNURLAmountRange, check: LNURLAmountRange.Check) -> String {
        switch check {
        case .tooSmall(let min): return "The smallest amount it accepts is \(min.formatted()) sats."
        case .tooLarge(let max): return "The largest amount it accepts is \(max.formatted()) sats."
        default: return "Between \(range.minSats.formatted()) and \(range.maxSats.formatted()) sats."
        }
    }

    private func sendButtonTitle(_ check: LNURLAmountRange.Check) -> String {
        if case .ok(let msat) = check { return "Send \((msat / 1000).formatted()) sats" }
        return "Send"
    }

    private func lnurlPayConfirmation(_ check: LNURLAmountRange.Check) -> String {
        guard case .ok(let msat) = check else { return "" }
        return "This sends \((msat / 1000).formatted()) sats from your wallet to \(counterpartyName). Lightning payments cannot be reversed."
    }

    /// The `text/plain` line of LNURL-pay metadata — the service's own
    /// description of what you are paying for.
    private static func plainTextMetadata(_ metadata: String) -> String? {
        guard let data = metadata.data(using: .utf8),
              let entries = try? JSONSerialization.jsonObject(with: data) as? [[Any]] else { return nil }
        for entry in entries where entry.count >= 2 && (entry[0] as? String) == "text/plain" {
            if let text = entry[1] as? String, !text.isEmpty { return text }
        }
        return nil
    }

    /// Looks up an address or LNURL once the user stops typing.
    private func resolveLNURLIfNeeded() async {
        resolved = nil
        resolveError = nil
        lnurlComment = ""
        guard let target = payTarget else { isResolving = false; return }
        if case .invoice = target { isResolving = false; return }
        isResolving = true
        try? await Task.sleep(nanoseconds: 400_000_000)
        guard !Task.isCancelled else { return }
        do {
            let r = try await LNURLService.resolve(target)
            guard !Task.isCancelled else { return }
            resolved = r
            switch r {
            case .pay(let pay, _):
                let range = LNURLAmountRange(minMsat: pay.minSendable, maxMsat: pay.maxSendable)
                lnurlAmountSats = range.isFixed ? String(range.minSats) : ""
            case .withdraw(let w, _):
                // A voucher is usually meant to be taken whole.
                lnurlAmountSats = String(LNURLAmountRange(minMsat: w.minWithdrawable, maxMsat: w.maxWithdrawable).maxSats)
            }
        } catch {
            guard !Task.isCancelled else { return }
            if case .address(let a) = target {
                resolveError = "Couldn't find the lightning address \(a). Check the spelling. (\(error.localizedDescription))"
            } else {
                resolveError = "Couldn't open this LNURL: \(error.localizedDescription)"
            }
        }
        isResolving = false
    }

    private func payLNURL(_ pay: LNURLService.LNURLPayResponse, range: LNURLAmountRange) {
        guard case .ok(let msat) = range.check(sats: Int(lnurlAmountSats)) else { return }
        let sats = msat / 1000
        let name = counterpartyName
        let comment = lnurlComment.trimmingCharacters(in: .whitespacesAndNewlines)
        isSending = true
        sendError = nil
        sendResult = nil
        Task {
            do {
                let invoice = try await LNURLService.fetchInvoice(
                    callback: pay.callback, amountMsat: msat, zapRequest: nil,
                    comment: comment.isEmpty ? nil : comment
                )
                // LUD-06: never pay an invoice for a different amount than the
                // one asked for — a service that swaps it is either broken or
                // stealing.
                guard Bolt11.msat(invoice) == msat else {
                    sendError = "\(name) returned an invoice for a different amount, so nothing was sent."
                    isSending = false
                    return
                }
                do {
                    _ = try await NWCService.payInvoice(bolt11: invoice)
                } catch NWCService.NWCError.notConnected {
                    // The request may have reached the wallet and be paying
                    // right now. Retrying would fetch a NEW invoice from the
                    // service and pay twice, so clear the form instead of
                    // leaving Send one tap away.
                    sendError = "Your wallet didn't confirm in time. The payment may still go through, so check History before sending again."
                    invoiceToPay = ""
                    isSending = false
                    try? await Task.sleep(nanoseconds: 5_000_000_000)
                    fetchBalance()
                    loadHistory(reset: true)
                    return
                }
                sendResult = "Sent \(sats.formatted()) sats to \(name)."
                invoiceToPay = ""
                isSending = false
                fetchBalance()
                loadHistory(reset: true)
            } catch {
                sendError = error.localizedDescription
                isSending = false
            }
        }
    }

    private func withdrawLNURL(_ w: LNURLService.LNURLWithdrawResponse, range: LNURLAmountRange) {
        guard case .ok(let msat) = range.check(sats: Int(lnurlAmountSats)) else { return }
        let sats = msat / 1000
        let name = counterpartyName
        isWithdrawing = true
        sendError = nil
        sendResult = nil
        Task {
            do {
                let invoice = try await NWCService.makeInvoice(amountMsats: msat, description: w.defaultDescription)
                try await LNURLService.submitWithdraw(w, invoice: invoice)
                sendResult = "\(name) is sending you \(sats.formatted()) sats. It shows up in History once it lands."
                invoiceToPay = ""
                isWithdrawing = false
                // The service pays asynchronously; look again once it has had a moment.
                try? await Task.sleep(nanoseconds: 4_000_000_000)
                fetchBalance()
                loadHistory(reset: true)
            } catch {
                sendError = error.localizedDescription
                isWithdrawing = false
            }
        }
    }

    // MARK: - History

    private var historyCard: some View {
        VStack(spacing: 12) {
            HStack {
                Image(systemName: "clock.arrow.circlepath")
                    .font(.appSystem(size: 14, weight: .semibold))
                    .foregroundColor(.secondary)
                Text("HISTORY")
                    .font(.appSystem(size: 12, weight: .bold))
                    .foregroundColor(.secondary)
                Spacer()
                if isLoadingHistory {
                    ProgressView().controlSize(.small)
                } else if !historyUnsupported {
                    Button(action: { loadHistory(reset: true) }) {
                        Image(systemName: "arrow.clockwise")
                            .font(.appSystem(size: 12, weight: .semibold))
                            .foregroundColor(.secondary)
                            .frame(width: 28, height: 28)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("Refresh")
                }
            }

            if historyUnsupported {
                Text("Your wallet doesn't share its payment history with apps. If it supports it, reconnect the wallet with \"transaction history\" (list transactions) allowed.")
                    .font(.appCaption)
                    .foregroundColor(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else if let historyError, transactions.isEmpty {
                Text(historyError)
                    .font(.appCaption)
                    .foregroundColor(.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else if transactions.isEmpty && !isLoadingHistory {
                Text("No payments yet.")
                    .font(.appCaption)
                    .foregroundColor(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                VStack(spacing: 0) {
                    ForEach(transactions) { tx in
                        transactionRow(tx)
                        if tx.id != transactions.last?.id {
                            Divider().opacity(0.5)
                        }
                    }
                }
                if canLoadMoreHistory {
                    Button(action: { loadHistory(reset: false) }) {
                        Text("Show more")
                            .font(.appSystem(size: 13, weight: .medium))
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .disabled(isLoadingHistory)
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

    /// A zap row opens the zapped post; anything else is just a row.
    @ViewBuilder
    private func transactionRow(_ tx: WalletTransaction) -> some View {
        if let postId = zapDetails[tx.id]?.postId, let post = zapPosts[postId] {
            NavigationLink(value: post) {
                transactionRowContent(tx)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        } else {
            transactionRowContent(tx)
        }
    }

    private func transactionRowContent(_ tx: WalletTransaction) -> some View {
        let incoming = tx.direction == .incoming
        let zap = zapDetails[tx.id]
        let person = zap?.counterparty(me: nostrService.activeHexPubkey, direction: tx.direction)
        return HStack(spacing: 12) {
            if let person {
                AvatarView(url: nostrService.profiles[person]?.pictureURL, pubkey: person, size: 28)
                    .overlay(alignment: .bottomTrailing) {
                        Image(systemName: "bolt.fill")
                            .font(.appSystem(size: 8, weight: .bold))
                            .foregroundColor(.white)
                            .padding(2)
                            .background(Circle().fill(Color.orange))
                            .offset(x: 3, y: 3)
                    }
            } else {
                Image(systemName: zap != nil ? "bolt.fill" : (incoming ? "arrow.down.left" : "arrow.up.right"))
                    .font(.appSystem(size: 13, weight: .bold))
                    .foregroundColor(zap != nil ? .orange : (incoming ? .green : .orange))
                    .frame(width: 28, height: 28)
                    .background((zap != nil ? Color.orange : (incoming ? Color.green : Color.orange)).opacity(0.12))
                    .clipShape(Circle())
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(transactionTitle(tx, zap: zap, person: person))
                    .font(.appSystem(size: 13, weight: .medium))
                    .foregroundColor(.primary)
                    .lineLimit(1)
                if let line = zapContextLine(zap, incoming: incoming) {
                    Text(line)
                        .font(.appCaption)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }
                Text(transactionSubtitle(tx))
                    .font(.appCaption)
                    .foregroundColor(tx.state == .failed || tx.state == .expired ? .red : .secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            Text("\(incoming ? "+" : "−")\(formatSats(tx.amountSats))")
                .font(.appSystem(size: 14, weight: .semibold, design: .rounded))
                .foregroundColor(tx.state == .settled ? (incoming ? .green : .primary) : .secondary)
                .strikethrough(tx.state == .failed || tx.state == .expired)
        }
        .padding(.vertical, 8)
    }

    private func transactionTitle(_ tx: WalletTransaction, zap: ZapDetail?, person: String?) -> String {
        let incoming = tx.direction == .incoming
        guard let zap else { return tx.description ?? (incoming ? "Received" : "Sent") }
        if incoming && zap.isAnonymous { return "Anonymous zap" }
        guard let person else { return incoming ? "Zap received" : "Zap sent" }
        let name = nostrService.profiles[person]?.bestName ?? ("npub…" + String(person.suffix(6)))
        return incoming ? "Zap from \(name)" : "Zap to \(name)"
    }

    /// What the zap was for: the sender's comment, else the start of the post.
    private func zapContextLine(_ zap: ZapDetail?, incoming: Bool) -> String? {
        guard let zap else { return nil }
        if let comment = zap.comment { return "\u{201C}\(comment)\u{201D}" }
        if let id = zap.postId, let post = zapPosts[id] {
            let text = post.content
                .replacingOccurrences(of: "\n", with: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return text.isEmpty ? "on a post" : "on: \(text)"
        }
        return zap.postId != nil ? "on a post" : (incoming ? "on your profile" : "on their profile")
    }

    /// Looks up who each zap on this page came from, without holding up the list.
    private func resolveZaps(_ page: [WalletTransaction]) {
        let me = nostrService.activeHexPubkey
        Task {
            let found = await ZapHistoryService.lookup(for: page, me: me)
            zapDetails.merge(found.details) { _, new in new }
            zapPosts.merge(found.posts) { _, new in new }
        }
    }

    private func transactionSubtitle(_ tx: WalletTransaction) -> String {
        var parts = [tx.createdAt.formatted(.relative(presentation: .named))]
        switch tx.state {
        case .pending: parts.append("pending")
        case .failed: parts.append("failed")
        case .expired: parts.append("expired")
        case .settled: break
        }
        if tx.direction == .outgoing && tx.feeSats > 0 {
            parts.append("fee \(formatSats(tx.feeSats))")
        }
        return parts.joined(separator: " · ")
    }

    private func loadHistory(reset: Bool) {
        guard !isLoadingHistory else {
            // A payment just finished while a page was loading: refresh after.
            if reset { historyRefreshPending = true }
            return
        }
        isLoadingHistory = true
        historyError = nil
        let offset = reset ? 0 : transactions.count
        Task {
            do {
                let page = try await NWCService.listTransactions(limit: Self.historyPageSize, offset: offset)
                transactions = reset ? page : WalletTransaction.merge(transactions, page)
                resolveZaps(page)
                canLoadMoreHistory = page.count >= Self.historyPageSize
                historyUnsupported = false
            } catch let err as NWCService.WalletError where err.isUnsupported {
                historyUnsupported = true
            } catch {
                historyError = "Couldn't load history: \(error.localizedDescription)"
            }
            isLoadingHistory = false
            if historyRefreshPending {
                historyRefreshPending = false
                loadHistory(reset: true)
            }
        }
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

    /// What you are about to spend.
    ///
    /// The button pays whatever is in the box, and a bolt11 invoice states its
    /// amount in a form nobody can read at a glance, so without this the sats
    /// leave before you ever see the number.
    ///
    /// Reading only — an invoice this app cannot parse is still payable, since
    /// the wallet on the other end is the authority on that, not us.
    @ViewBuilder
    private var invoiceAmountLine: some View {
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
    private var payConfirmationMessage: String {
        switch Bolt11.amount(parsedInvoice) {
        case .sats(let sats):
            return "This sends \(sats.formatted()) sats from your wallet. Lightning payments cannot be reversed."
        case .unspecified:
            return "This invoice names no amount, so your wallet decides what to send — and it may refuse it outright. Lightning payments cannot be reversed."
        case .unreadable:
            return "Nostr Vault cannot read this invoice, so it cannot tell you what it will cost. Your wallet will pay whatever it says. Lightning payments cannot be reversed."
        }
    }

    private func payInvoice() {
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
