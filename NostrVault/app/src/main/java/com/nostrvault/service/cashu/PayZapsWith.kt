package com.nostrvault.service.cashu

import android.content.Context
import android.content.SharedPreferences
import dagger.hilt.android.qualifiers.ApplicationContext
import javax.inject.Inject
import javax.inject.Singleton

/** Which wallet pays an account's zaps: the NWC link or the built-in Cashu wallet. */
enum class ZapWallet(val raw: String) {
    NWC("nwc"),
    CASHU("cashu");

    companion object {
        fun from(raw: String?): ZapWallet? = entries.firstOrNull { it.raw == raw }
    }
}

/**
 * The per-account "Pay zaps with" choice (design §6; Apple twin
 * `PayZapsWith.swift`). No choice yet means NWC, so nothing changes until the
 * user picks Built-in in Settings › Wallet (step D3). The prefs file is not in
 * Auto Backup, so a restored phone starts on NWC again.
 */
@Singleton
class PayZapsWith(private val prefs: () -> SharedPreferences) {
    @Inject constructor(@ApplicationContext context: Context) :
        this({ context.getSharedPreferences(PREFS, Context.MODE_PRIVATE) })

    fun key(accountHex: String) = KEY_PREFIX + accountHex.lowercase()

    /** The account's choice; NWC when it has none (or an unknown value). */
    fun choice(accountHex: String): ZapWallet = stored(accountHex) ?: ZapWallet.NWC

    /** The saved choice itself, null when the user never picked. */
    fun stored(accountHex: String): ZapWallet? =
        if (accountHex.isEmpty()) null else ZapWallet.from(prefs().getString(key(accountHex), null))

    fun set(wallet: ZapWallet, accountHex: String) {
        if (accountHex.isEmpty()) return
        prefs().edit().putString(key(accountHex), wallet.raw).apply()
    }

    /** Forgets the choice (the account is removed): back to NWC. */
    fun clear(accountHex: String) {
        prefs().edit().remove(key(accountHex)).apply()
    }

    companion object {
        const val PREFS = "cashu_pay_zaps_with"
        const val KEY_PREFIX = "payZapsWith."
    }
}
