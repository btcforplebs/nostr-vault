import Foundation

/// The one payer seam (design §2 "NWC stays", §6): every place that pays a
/// bolt11 calls this instead of `NWCService.payInvoice`, and it pays from the
/// wallet the account chose in "Pay zaps with" (`PayZapsWith`): NWC by
/// default, or the built-in Cashu wallet. Callers keep their shape: the
/// preimage back (empty when a mint gives none), or a throw.
enum ZapPayer {
    /// Pays `bolt11` for `accountHex` (the active account when nil). `using`
    /// pins one wallet regardless of the choice: the NWC wallet screen pays
    /// from the wallet whose balance it shows.
    static func pay(bolt11: String, accountHex: String? = nil, using pinned: ZapWallet? = nil) async throws -> String {
        let account: String
        if let accountHex { account = accountHex } else { account = await activeAccountHex() }
        switch pinned ?? PayZapsWith.choice(accountHex: account) {
        case .nwc:
            return try await NWCService.payInvoice(bolt11: bolt11)
        case .cashu:
            // A chosen built-in wallet that isn't on this device fails closed:
            // never fall back to NWC and pay from a wallet the user didn't pick.
            let wallet = try CashuWalletService.wallet(accountHex: account)
            let result = try await wallet.payInvoice(bolt11: bolt11)
            return result.preimage ?? ""
        }
    }

    /// The request went out and may still be paid: wait for the receipt,
    /// don't call it failed and don't pay again.
    static func mayStillSettle(_ error: Error) -> Bool {
        if let nwc = error as? NWCService.NWCError { return nwc.mayStillSettle }
        if let cashu = error as? CashuError { return cashu.mayStillSettle }
        return false
    }

    /// The account the app acts as now, as hex ("" when there is none).
    @MainActor static func activeAccountHex() -> String {
        let config = ConfigService.shared.config
        let npub = PostingAccount.resolve(active: config.activeAccountNpub, owner: config.ownerNpub)
        return Bech32.decode(npub)?.hexString ?? ""
    }

    /// `npub` as hex, for callers that hold the account as an npub.
    static func hex(ofNpub npub: String) -> String {
        Bech32.decode(npub)?.hexString ?? ""
    }
}
