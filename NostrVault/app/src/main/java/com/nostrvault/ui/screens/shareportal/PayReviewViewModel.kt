package com.nostrvault.ui.screens.shareportal

import android.content.Context
import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import com.nostrvault.data.local.ConfigStore
import com.nostrvault.data.model.PostingAccount
import com.nostrvault.service.LNURLPayResponse
import com.nostrvault.service.LNURLResolved
import com.nostrvault.service.LNURLService
import com.nostrvault.service.NWCNotSentException
import com.nostrvault.service.NWCService
import com.nostrvault.service.NWCTimeoutException
import com.nostrvault.service.NWCWalletException
import com.nostrvault.service.NostrService
import com.nostrvault.service.shareportal.handlers.PayShareHandler
import com.nostrvault.shareportal.PayShareTarget
import com.nostrvault.shareportal.ShareIntent
import com.nostrvault.util.Bolt11
import com.nostrvault.util.Bolt11Amount
import com.nostrvault.util.Bolt11Details
import com.nostrvault.util.LightningPayTarget
import com.nostrvault.util.RelayGiven
import com.nostrvault.util.ZapComment
import dagger.hilt.android.lifecycle.HiltViewModel
import dagger.hilt.android.qualifiers.ApplicationContext
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch
import kotlinx.serialization.json.add
import kotlinx.serialization.json.buildJsonArray
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.put
import javax.inject.Inject

/**
 * The Pay or zap review card's work. Twin: PayShareHandler.swift. See
 * [PayShareHandler] for the money rules this enforces.
 */
@HiltViewModel
class PayReviewViewModel @Inject constructor(
    @ApplicationContext context: Context,
    private val nwcService: NWCService,
    private val nostrService: NostrService,
    private val configStore: ConfigStore,
) : ViewModel() {
    private val attempts = PayShareAttempts(context.getSharedPreferences("share_portal_pay", Context.MODE_PRIVATE))

    sealed interface Lnurl {
        data object Idle : Lnurl
        data object Resolving : Lnurl
        data class Ready(val pay: LNURLPayResponse, val host: String) : Lnurl
        data class Failed(val message: String) : Lnurl
    }

    private val _lnurl = MutableStateFlow<Lnurl>(Lnurl.Idle)
    val lnurl: StateFlow<Lnurl> = _lnurl.asStateFlow()
    private val _busy = MutableStateFlow(false)
    val busy: StateFlow<Boolean> = _busy.asStateFlow()
    private val _error = MutableStateFlow<String?>(null)
    val error: StateFlow<String?> = _error.asStateFlow()
    private val _done = MutableStateFlow<String?>(null)
    val done: StateFlow<String?> = _done.asStateFlow()
    /** Bumped after a pay attempt, so the card re-reads [attempt]. */
    private val _attemptTick = MutableStateFlow(0)
    val attemptTick: StateFlow<Int> = _attemptTick.asStateFlow()

    val hasWallet: Boolean get() = !configStore.config.value.nwcURI.isNullOrBlank()

    fun attempt(intent: ShareIntent): PayShareAttempts.State? = attempts.state(intent.id)

    /** The account whose wallet pays (and who signs a zap). */
    fun account(intent: ShareIntent): String = intent.account ?: configStore.config.value.activeOrOwnerNpub()

    fun isActive(intent: ShareIntent): Boolean = account(intent) == configStore.config.value.activeOrOwnerNpub()

    fun recipientHex(target: PayShareTarget): String? = target.recipientNpub?.let(nostrService::npubToHex)

    fun recipientName(hex: String): String = nostrService.profiles.value[hex]?.bestName ?: "them"

    /** True when a zap may be offered: see [PayShareTarget.canZap]. */
    fun zapOffered(target: PayShareTarget, pay: LNURLPayResponse): Boolean {
        val hex = recipientHex(target) ?: return false
        if (pay.allowsNostr != true || pay.nostrPubkey.isNullOrBlank()) return false
        return PayShareTarget.canZap(target, nostrService.profiles.value[hex]?.lud16)
    }

    fun resolve(target: PayShareTarget) {
        if (target.kind == PayShareTarget.Kind.INVOICE || _lnurl.value !is Lnurl.Idle) return
        val parsed = LightningPayTarget.parse(target.token) ?: run { _lnurl.value = Lnurl.Failed("Not something Nostr Vault can pay."); return }
        _lnurl.value = Lnurl.Resolving
        viewModelScope.launch {
            _lnurl.value = try {
                when (val r = LNURLService.resolve(parsed)) {
                    is LNURLResolved.Pay -> Lnurl.Ready(r.pay, r.host)
                    is LNURLResolved.Withdraw -> Lnurl.Failed("This link pays you rather than asking for a payment. Open it from the Wallet screen.")
                }
            } catch (e: kotlinx.coroutines.CancellationException) {
                throw e
            } catch (e: Exception) {
                Lnurl.Failed(e.message ?: "Couldn't reach that payment service.")
            }
        }
    }

    /**
     * Pays a shared bolt11. Expiry and amount are checked again now, not only
     * when the card was drawn. Retrying the same invoice is safe: a wallet
     * cannot settle one payment hash twice.
     */
    fun payInvoice(intent: ShareIntent, invoice: String) {
        run(intent) {
            val details = Bolt11Details.read(invoice) ?: return@run "This invoice can't be read."
            if (details.amount !is Bolt11Amount.Sats) return@run NO_AMOUNT
            if (details.isExpired()) return@run EXPIRED
            if (!isActive(intent)) return@run ACCOUNT_CHANGED
            attempts.mark(intent.id, PayShareAttempts.State.TRIED)
            nwcService.payInvoice(invoice)
            attempts.mark(intent.id, PayShareAttempts.State.PAID)
            _done.value = "Paid."
            null
        }
    }

    /** LNURL-pay: a plain payment, or a public zap when [zap] (only if offered). */
    fun payLnurl(intent: ShareIntent, target: PayShareTarget, pay: LNURLPayResponse, host: String,
                 amountMsat: Long, comment: String, zap: Boolean) {
        run(intent) {
            if (attempts.state(intent.id) != null) return@run ALREADY_TRIED
            if (!isActive(intent)) return@run ACCOUNT_CHANGED
            val zapRequest = if (zap && zapOffered(target, pay)) {
                signZapRequest(intent, recipientHex(target)!!, target.token, amountMsat, comment)
                    ?: return@run "The zap request wasn't signed, so nothing was sent."
            } else null
            val invoice = LNURLService.fetchInvoice(
                callback = pay.callback,
                amountMsat = amountMsat,
                zapRequest = zapRequest,
                comment = comment.trim().takeIf { zapRequest == null && it.isNotEmpty() },
            )
            // LUD-06: exact msat, or a service could add up to 999 on top.
            if (Bolt11.msat(invoice) != amountMsat) return@run "$host returned an invoice for a different amount, so nothing was sent."
            if (Bolt11Details.read(invoice)?.isExpired() == true) return@run EXPIRED
            if (!isActive(intent)) return@run ACCOUNT_CHANGED
            // From here on a retry could pay twice: the card never offers one.
            attempts.mark(intent.id, PayShareAttempts.State.TRIED)
            nwcService.payInvoice(invoice)
            attempts.mark(intent.id, PayShareAttempts.State.PAID)
            _done.value = "Sent ${"%,d".format(amountMsat / 1000)} sats."
            null
        }
    }

    /** Runs [block]; a returned string is shown as the error. */
    private fun run(intent: ShareIntent, block: suspend () -> String?) {
        if (_busy.value) return
        _busy.value = true
        _error.value = null
        viewModelScope.launch {
            try {
                _error.value = block()
            } catch (e: kotlinx.coroutines.CancellationException) {
                throw e
            } catch (e: NWCTimeoutException) {
                _error.value = "Your wallet didn't confirm in time. The payment may still go through, so check History before paying again."
            } catch (e: NWCNotSentException) {
                // The request never reached the wallet: nothing can be paying.
                attempts.forget(intent.id)
                _error.value = e.message ?: "Nothing was sent."
            } catch (e: NWCWalletException) {
                if (e.refusedBeforePaying) attempts.forget(intent.id)
                _error.value = e.message ?: "Your wallet refused the payment."
            } catch (e: PostingAccount.AccountChangedException) {
                _error.value = ACCOUNT_CHANGED
            } catch (e: Exception) {
                _error.value = e.message ?: "Payment failed."
            } finally {
                _attemptTick.value++
                _busy.value = false
            }
        }
    }

    /**
     * Kind 9734, signed only as the share's account (locked, like a post),
     * never published by us: the LNURL service publishes the receipt.
     */
    private suspend fun signZapRequest(intent: ShareIntent, recipientHex: String, lnurl: String,
                                       amountMsat: Long, comment: String): String? {
        val npub = account(intent)
        val hex = nostrService.npubToHex(npub) ?: return null
        val config = configStore.config.value
        val relays = RelayGiven.zapReceiptRelays(
            ownRelay = config.nostrURL,
            feedRelays = config.activeFeedRelays,
            myInbox = nostrService.relayLists.value[hex].orEmpty(),
            recipientInbox = nostrService.relayLists.value[recipientHex].orEmpty(),
        )
        val tags = listOf(
            listOf("p", recipientHex),
            listOf("relays") + relays,
            listOf("amount", amountMsat.toString()),
            listOf("lnurl", lnurl),
        )
        // A literal kind: UserListSignGuardTest flags a signer whose kind is a variable.
        val event = nostrService.signEventAsync(
            kind = 9734, content = ZapComment.content(comment), tags = tags,
            lockedTo = PostingAccount.Lock(npub = npub, hex = hex),
        ) ?: return null
        return buildJsonObject {
            put("id", event.id)
            put("pubkey", event.pubkey)
            put("created_at", event.createdAt)
            put("kind", event.kind)
            put("tags", buildJsonArray { event.tags.forEach { tag -> add(buildJsonArray { tag.forEach { add(it) } }) } })
            put("content", event.content)
            put("sig", event.sig)
        }.toString()
    }

    companion object {
        const val NO_AMOUNT = "This invoice names no amount. Nostr Vault won't pay it from a share."
        const val EXPIRED = "This invoice has expired, so nothing was sent."
        const val ACCOUNT_CHANGED = "The account changed, so nothing was sent."
        const val ALREADY_TRIED = "A payment was already tried from this share. Check your wallet's history."
    }
}

/**
 * What happened to each pay share, by intent id, kept outside the queue so a
 * card that comes back after the app was killed still knows. The newest 200.
 * Twin: PayShareAttempts in PayShareHandler.swift.
 */
class PayShareAttempts(private val prefs: android.content.SharedPreferences) {
    enum class State { TRIED, PAID }

    fun state(id: String): State? = entries().lastOrNull { it.first == id }?.second

    fun mark(id: String, state: State) {
        val list = entries().filter { it.first != id } + (id to state)
        prefs.edit().putString(KEY, list.takeLast(CAP).joinToString("\n") { "${it.first} ${it.second.name}" }).commit()
    }

    /** Only for a wallet call that provably never paid; a PAID entry stays. */
    fun forget(id: String) {
        if (state(id) != State.TRIED) return
        prefs.edit().putString(KEY, entries().filter { it.first != id }.joinToString("\n") { "${it.first} ${it.second.name}" }).commit()
    }

    private fun entries(): List<Pair<String, State>> =
        prefs.getString(KEY, null).orEmpty().lines().mapNotNull { line ->
            val parts = line.split(' ')
            if (parts.size != 2) return@mapNotNull null
            val s = runCatching { State.valueOf(parts[1]) }.getOrNull() ?: return@mapNotNull null
            parts[0] to s
        }

    private companion object {
        const val KEY = "attempts"
        const val CAP = 200
    }
}
