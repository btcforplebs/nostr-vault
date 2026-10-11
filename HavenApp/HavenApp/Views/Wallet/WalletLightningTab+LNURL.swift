import SwiftUI
import CoreImage.CIFilterBuiltins

extension WalletLightningTab {
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
    var lnurlSection: some View {
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
    func resolveLNURLIfNeeded() async {
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
}
