package com.nostrvault.service

import android.util.Log
import com.nostrvault.data.local.ConfigStore
import com.nostrvault.util.RelayGiven
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
) {
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
        class PaymentFailed(detail: String) : ZapError("Payment failed: $detail")
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
     */
    suspend fun zapNote(
        noteId: String,
        notePubkey: String,
        amountSats: Int,
        message: String = "Zap from Nostr Vault",
        addressTag: String? = null,
    ): Result<Unit> {
        if (amountSats <= 0) {
            return Result.failure(ZapError.PaymentFailed("Zap amount must be greater than 0"))
        }
        if (amountSats > MAX_ZAP_SATS) {
            return Result.failure(ZapError.PaymentFailed("Zap amount exceeds safety limit"))
        }
        val config = configStore.config.value
        if (config.nwcURI.isNullOrBlank()) {
            return Result.failure(ZapError.NoWallet())
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
            return Result.failure(ZapError.PaymentFailed("Amount outside provider limits ($min–$max sats)"))
        }

        // 2. Sign the kind-9734 zap request (only when the provider supports
        // NIP-57; otherwise pay a plain invoice with no receipt).
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
                    ),
                )
                // A stream zap has to be published where the room is watching,
                // or the receipt never shows up in its chat.
                if (addressTag != null) addAll(LiveChatService.STREAMING_RELAYS)
            }.distinct()
            val tags = buildList {
                add(listOf("p", notePubkey))
                add(listOf("relays") + relayList)
                add(listOf("amount", amountMsat.toString()))
                if (noteId.isNotEmpty()) add(listOf("e", noteId))
                addressTag?.let { add(listOf("a", it, LiveChatService.STREAMING_RELAYS.first())) }
                if (lnurlTag.isNotEmpty()) add(listOf("lnurl", lnurlTag))
            }
            val signed = try {
                nostrService.signEventAsync(kind = 9734, content = message, tags = tags)
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

        // 4. Pay via NWC.
        try {
            val preimage = nwcService.payInvoice(invoice)
            Log.i(TAG, "Zap paid ($amountSats sats): $preimage")
        } catch (e: Exception) {
            Log.w(TAG, "NWC payment failed: ${e.message}")
            return Result.failure(ZapError.PaymentFailed(e.message ?: "unknown error"))
        }

        // Optimistic local bump; the real kind-9735 receipt overwrites this
        // when the engagement subscriptions next ingest it.
        feedService.zapNote(noteId, amountSats.toLong())
        return Result.success(Unit)
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
