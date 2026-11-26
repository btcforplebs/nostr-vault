package com.nostrvault.service

import android.util.Log
import com.nostrvault.data.local.ConfigStore
import com.nostrvault.service.cashu.CashuException
import com.nostrvault.service.cashu.ZapPayer
import com.nostrvault.util.Bolt11
import com.nostrvault.util.RelayGiven
import com.nostrvault.ui.notification.NotificationManager
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.async
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlinx.coroutines.selects.select
import kotlinx.coroutines.withTimeoutOrNull
import kotlinx.serialization.json.add
import kotlinx.serialization.json.buildJsonArray
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.put
import javax.inject.Inject
import javax.inject.Singleton

/**
 * NIP-57 zap sending: LNURL resolution -> signed kind-9734 zap request ->
 * invoice fetch -> NWC payment. Port of iOS ZapService.swift (the receipt
 * parser lives in ZapService.kt).
 */
@Singleton
class ZapSendService @Inject constructor(
    private val nostrService: NostrService,
    private val nwcService: NWCService,
    private val configStore: ConfigStore,
    private val feedService: FeedService,
    private val notificationManager: NotificationManager,
    /** The "Pay zaps with" seam (service/cashu). Null (tests) pays by NWC as before. */
    private val zapPayer: ZapPayer? = null,
) {
    /** Zaps waiting on their wallet or receipt ([PendingZaps]). */
    internal val pendingZaps = PendingZaps()
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)

    companion object {
        private const val TAG = "ZapSendService"
        private const val MAX_ZAP_SATS = 10_000_000
    }

    sealed class ZapError(message: String) : Exception(message) {
        class NoLightningAddress : ZapError("Author has no lightning address")
        class NoWallet : ZapError("No wallet connected. Add an NWC connection on the Wallet screen.")
        class LnurlFailed : ZapError("Failed to resolve lightning address")
        class SignFailed : ZapError("Failed to sign zap request")
        class InvoiceFailed : ZapError("Failed to fetch invoice from provider")
        /** The provider's invoice is not for the amount the user chose; nothing was paid. */
        class WrongInvoiceAmount : ZapError("The provider returned an invoice for a different amount, so nothing was sent.")
        /** [notPaid]: the wallet never paid (it was never asked, or refused), so trying again can't pay twice. */
        class PaymentFailed(val detail: String, val notPaid: Boolean = false) : ZapError("Payment failed: $detail")
        /** Sent, but the wallet never confirmed: not a failure. Its receipt may still light the bolt (ZapConfirm). */
        class MayStillArrive : ZapError("Sent. Your wallet hasn't confirmed yet, so it may still arrive.")
        /** A zap on this note is still pending; a second tap sends another (PendingZaps). */
        class StillPending : ZapError("Your last zap here may still be on its way. Tap zap again to send another.")
    }

    /** The outcome of asking the wallet, or of seeing the receipt first. */
    private sealed interface Payment {
        data object Paid : Payment
        data object Unconfirmed : Payment
        data class Failed(val error: Exception) : Payment
    }

    /**
     * Execute a full zap. [noteId] must be the effective (inner) event id for
     * reposts — see FeedNote.effectiveEventId. Returns success once the wallet
     * has paid; the kind-9735 receipt then propagates via relays and is picked
     * up by the existing FeedService 9735 ingestion.
     */
    /**
     * @param addressTag the NIP-01 addressable identifier to attribute the zap
     *   to, e.g. `30311:<host>:<d>` for a live stream. Live clients read the
     *   `a` tag to decide which room a zap belongs in — without it the zap
     *   pays the host but never appears in the stream's chat.
     * @param extraReceiptRelays relays someone else needs to find the receipt
     *   on: a gated article's key server reads the relays its author named in
     *   the `zap` tags. They go first in the `relays` tag (never cut by the
     *   cap), and the first one is the `a` tag's relay hint. When given, the
     *   live-stream relays are not added: the zap is for that article, not a
     *   room. iOS ZapService.zapNote(..., extraReceiptRelays:).
     */
    suspend fun zapNote(
        noteId: String,
        notePubkey: String,
        amountSats: Int,
        message: String = "",
        addressTag: String? = null,
        extraReceiptRelays: List<String> = emptyList(),
    ): Result<Unit> {
        // The account that tapped Zap: its "Pay zaps with" wallet pays.
        val payingAccount = if (zapPayer != null) nostrService.activeHexPubkey else ""
        if (amountSats <= 0) {
            return Result.failure(ZapError.PaymentFailed("Zap amount must be greater than 0", notPaid = true))
        }
        if (amountSats > MAX_ZAP_SATS) {
            return Result.failure(ZapError.PaymentFailed("Zap amount exceeds safety limit", notPaid = true))
        }
        val config = configStore.config.value
        if (config.nwcURI.isNullOrBlank()) {
            return Result.failure(ZapError.NoWallet())
        }
        val pendingKey = PendingZaps.key(noteId, notePubkey)
        if (!pendingZaps.mayZap(pendingKey)) {
            return Result.failure(ZapError.StillPending())
        }
        val amountMsat = amountSats.toLong() * 1000

        // 1. Resolve the recipient's lightning address (LUD-16 or LUD-06).
        val profile = nostrService.profiles.value[notePubkey]
        val lud16 = profile?.lud16?.takeIf { it.isNotBlank() }
        val lud06 = profile?.lud06?.takeIf { it.isNotBlank() }
        val lnurlResponse = try {
            when {
                lud16 != null && lud16.contains("@") -> LNURLService.resolveAddress(lud16)
                lud06 != null -> LNURLService.resolveRawLNURL(lud06)
                lud16 != null && lud16.lowercase().startsWith("lnurl") ->
                    LNURLService.resolveRawLNURL(lud16)
                else -> return Result.failure(ZapError.NoLightningAddress())
            }
        } catch (e: Exception) {
            Log.w(TAG, "LNURL resolution failed: ${e.message}")
            return Result.failure(ZapError.LnurlFailed())
        }

        if (amountMsat < lnurlResponse.minSendable || amountMsat > lnurlResponse.maxSendable) {
            val min = lnurlResponse.minSendable / 1000
            val max = lnurlResponse.maxSendable / 1000
            return Result.failure(ZapError.PaymentFailed("Amount outside provider limits ($min–$max sats)", notPaid = true))
        }

        // 2. Sign the kind-9734 zap request (only when the provider supports
        // NIP-57; otherwise pay a plain invoice with no receipt).
        var receiptRelays: List<String> = emptyList()
        val requestedAt = System.currentTimeMillis() / 1000
        val zapRequestJson = if (lnurlResponse.allowsNostr == true) {
            val lnurlTag = (lud16 ?: lud06 ?: "").removePrefix("lnurl:").removePrefix("LNURL:")
            // The provider publishes the receipt to these relays, so they must
            // be ones it can reach and that get read: the relays Given and the
            // feed query, your published inbox, and the recipient's inbox
            // (iOS #296). A phone-local relay is left out; no provider reaches it.
            val relayLists = nostrService.relayLists.value
            val relayList = buildList {
                addAll(
                    RelayGiven.zapReceiptRelays(
                        ownRelay = config.nostrURL,
                        feedRelays = config.activeFeedRelays,
                        myInbox = relayLists[nostrService.activeHexPubkey].orEmpty(),
                        recipientInbox = relayLists[notePubkey].orEmpty(),
                        extra = extraReceiptRelays,
                    ),
                )
                // A stream zap has to be published where the room is watching,
                // or the receipt never shows up in its chat.
                if (addressTag != null && extraReceiptRelays.isEmpty()) addAll(LiveChatService.STREAMING_RELAYS)
            }.distinct()
            receiptRelays = relayList
            val tags = buildList {
                add(listOf("p", notePubkey))
                add(listOf("relays") + relayList)
                add(listOf("amount", amountMsat.toString()))
                if (noteId.isNotEmpty()) add(listOf("e", noteId))
                addressTag?.let { add(listOf("a", it, extraReceiptRelays.firstOrNull() ?: LiveChatService.STREAMING_RELAYS.first())) }
                if (lnurlTag.isNotEmpty()) add(listOf("lnurl", lnurlTag))
            }
            val signed = try {
                nostrService.signEventAsync(kind = 9734, content = com.nostrvault.util.ZapComment.content(message), tags = tags)
            } catch (e: Exception) {
                Log.w(TAG, "Zap request signing failed: ${e.message}")
                null
            } ?: return Result.failure(ZapError.SignFailed())
            eventToWireJson(signed)
        } else null

        // 3. Fetch the BOLT-11 invoice.
        val invoice = try {
            LNURLService.fetchInvoice(
                callback = lnurlResponse.callback,
                amountMsat = amountMsat,
                zapRequest = zapRequestJson,
            )
        } catch (e: Exception) {
            Log.w(TAG, "Invoice fetch failed: ${e.message}")
            return Result.failure(ZapError.InvoiceFailed())
        }

        // LUD-06 / NIP-57: never pay an invoice for a different amount than
        // the one asked for. A provider that swaps it is broken or stealing,
        // and the wallet would pay up to its whole budget. Exact msat, the
        // same check the wallet's own pay paths make (WalletScreen.kt).
        if (Bolt11.msat(invoice) != amountMsat) {
            Log.w(TAG, "Invoice amount mismatch, not paying")
            return Result.failure(ZapError.WrongInvoiceAmount())
        }

        // 4. Pay (NWC or the built-in wallet, ZapPayer), and watch for the zap's own receipt meanwhile: either
        // one proves it went (ZapConfirm). Only a receipt-carrying zap can be
        // watched; a plain invoice has only the wallet's word.
        pendingZaps.begin(pendingKey)
        val receipt = receiptRelays.takeIf { zapRequestJson != null && it.isNotEmpty() }
            ?.let { relays -> ReceiptWatch(invoice, ZapConfirm.receiptFilter(notePubkey, noteId, requestedAt), relays) }
        val payment = pay(invoice, payingAccount, receipt)
        return when (payment) {
            Payment.Paid -> {
                Log.i(TAG, "Zap paid ($amountSats sats)")
                pendingZaps.end(pendingKey)
                // Optimistic local bump; the real kind-9735 receipt overwrites this
                // when the engagement subscriptions next ingest it.
                feedService.zapNote(noteId, amountSats.toLong())
                Result.success(Unit)
            }
            Payment.Unconfirmed -> {
                Log.i(TAG, "Zap sent, wallet unconfirmed; watching for its receipt")
                if (receipt != null) watchLate(receipt, pendingKey, noteId, notePubkey, amountSats)
                Result.failure(ZapError.MayStillArrive())
            }
            is Payment.Failed -> {
                pendingZaps.end(pendingKey)
                val e = payment.error
                Log.w(TAG, "Zap payment failed: ${e.message}")
                val notPaid = e is NWCNotSentException || (e is NWCWalletException && e.refusedBeforePaying) ||
                    (e is CashuException && e.refusedBeforePaying)
                val shown = (e as? CashuException)?.userMessage ?: e.message ?: "unknown error"
                Result.failure(ZapError.PaymentFailed(shown, notPaid))
            }
        }
    }

    /** Where and how to find a zap's receipt. */
    private class ReceiptWatch(val invoice: String, val filter: String, val relays: List<String>)

    /**
     * The wallet's answer, or the receipt if it comes first. No answer within
     * the wallet wait, or one without a preimage, is [Payment.Unconfirmed].
     */
    private suspend fun pay(invoice: String, account: String, receipt: ReceiptWatch?): Payment = coroutineScope {
        val wallet = async {
            try {
                if (zapPayer != null) zapPayer.pay(invoice, account) else nwcService.payInvoice(invoice)
                Payment.Paid
            } catch (e: NWCTimeoutException) {
                Payment.Unconfirmed
            } catch (e: NWCNoPreimageException) {
                Payment.Unconfirmed
            } catch (e: CashuException) {
                // "pending": the mint may still pay, so wait for the receipt.
                if (e.mayStillSettle) Payment.Unconfirmed else Payment.Failed(e)
            } catch (e: Exception) {
                if (e is kotlinx.coroutines.CancellationException) throw e
                Payment.Failed(e)
            }
        }
        if (receipt == null) return@coroutineScope wallet.await()
        // Never completes unless the receipt shows up; cancelled with the wallet's answer.
        val seen = async {
            while (!receiptSeen(receipt)) delay(ZapConfirm.RECEIPT_POLL_MS)
            Payment.Paid
        }
        val first = select<Payment> {
            wallet.onAwait { it }
            seen.onAwait { it }
        }
        wallet.cancel()
        seen.cancel()
        first
    }

    private suspend fun receiptSeen(watch: ReceiptWatch): Boolean = try {
        nostrService.queryRawEvents(listOf(watch.filter), watch.relays, ZapConfirm.RECEIPT_QUERY_MS)
            .any { ZapConfirm.receiptPaysInvoice(it, watch.invoice) }
    } catch (e: Exception) {
        if (e is kotlinx.coroutines.CancellationException) throw e
        false
    }

    /**
     * The wallet never confirmed: keep looking for the receipt a while longer.
     * Seen, the bolt lights and a "Zapped" pill says so; not seen, the zap stays
     * "may still arrive" (it was never called failed).
     */
    private fun watchLate(watch: ReceiptWatch, pendingKey: String, noteId: String, notePubkey: String, amountSats: Int) {
        scope.launch {
            val seen = withTimeoutOrNull(ZapConfirm.RECEIPT_WATCH_MS) {
                while (!receiptSeen(watch)) delay(ZapConfirm.RECEIPT_POLL_MS)
                true
            } == true
            pendingZaps.end(pendingKey)
            if (!seen) return@launch
            Log.i(TAG, "Zap confirmed by its receipt")
            feedService.zapNote(noteId, amountSats.toLong())
            val name = nostrService.profiles.value[notePubkey]?.bestName ?: notePubkey.take(8)
            notificationManager.zapConfirmedLater(name, amountSats)
        }
    }

    /** Serialize a signed event to wire-format JSON (snake_case created_at). */
    private fun eventToWireJson(event: NostrEvent): String = buildJsonObject {
        put("id", event.id)
        put("pubkey", event.pubkey)
        put("created_at", event.createdAt)
        put("kind", event.kind)
        put("tags", buildJsonArray {
            event.tags.forEach { tag -> add(buildJsonArray { tag.forEach { add(it) } }) }
        })
        put("content", event.content)
        put("sig", event.sig)
    }.toString()
}
