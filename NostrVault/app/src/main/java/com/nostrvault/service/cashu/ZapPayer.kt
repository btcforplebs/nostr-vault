package com.nostrvault.service.cashu

import com.nostrvault.service.NWCService
import javax.inject.Inject
import javax.inject.Singleton

/**
 * The payer seam (design §2 "NWC stays", §6; Apple twin `ZapPayer.swift`):
 * pays a bolt11 from the wallet the account chose in "Pay zaps with": NWC by
 * default, or the built-in Cashu wallet. Callers keep their shape: the
 * preimage back (empty when a mint gives none), or a throw.
 */
@Singleton
class ZapPayer @Inject constructor(
    private val nwc: NWCService,
    private val choice: PayZapsWith,
    private val wallets: CashuWallets,
) {
    /**
     * Pays [bolt11] for [accountHex]. [pinned] picks one wallet regardless of
     * the choice (the NWC wallet screen pays from the wallet it shows).
     */
    suspend fun pay(bolt11: String, accountHex: String, pinned: ZapWallet? = null): String =
        when (pinned ?: choice.choice(accountHex)) {
            ZapWallet.NWC -> nwc.payInvoice(bolt11)
            // A chosen built-in wallet that isn't on this device fails closed:
            // never fall back to NWC and pay from a wallet the user didn't pick.
            ZapWallet.CASHU -> wallets.wallet(accountHex).payInvoice(bolt11).preimage.orEmpty()
        }
}
