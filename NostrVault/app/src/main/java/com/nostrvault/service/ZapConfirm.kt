package com.nostrvault.service

import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.buildJsonArray
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.intOrNull
import kotlinx.serialization.json.put
import java.util.concurrent.ConcurrentHashMap

/**
 * A zap the wallet hasn't confirmed is not a failed zap
 * (RESEARCH/NV_MINIBITS_ZAP_REVIEW_2026_11_19.md, Logen 4f097fe0). A phone
 * wallet or a slow route can take well over a minute, so:
 *
 * - the wallet gets [WALLET_WAIT_MS] to answer `pay_invoice` (was 15 s);
 * - the zap's own receipt (kind 9735 for the exact invoice we paid) counts as
 *   paid, whether it shows up before the wallet answers or after;
 * - no answer is "may still arrive", never "failed", and a receipt arriving in
 *   the next [RECEIPT_WATCH_MS] still lights the bolt;
 * - zapping the same note again while one is pending asks first ([PendingZaps]).
 *
 * Same names and timings as the iPhone/Mac twin.
 */
object ZapConfirm {
    /** How long the wallet gets to answer pay_invoice. */
    const val WALLET_WAIT_MS = 90_000L
    /** After that, how long a receipt still lights the bolt. */
    const val RECEIPT_WATCH_MS = 120_000L
    /** How often the receipt relays are asked. */
    const val RECEIPT_POLL_MS = 10_000L
    /** How long one ask of the receipt relays may take. */
    const val RECEIPT_QUERY_MS = 6_000L

    /**
     * The kind-9735 filter for a zap's receipt: to [recipient], for [noteId]
     * when there is one, since a little before the zap request was signed.
     */
    fun receiptFilter(recipient: String, noteId: String, sinceSeconds: Long): String = buildJsonObject {
        put("kinds", buildJsonArray { add(JsonPrimitive(9735)) })
        put("#p", buildJsonArray { add(JsonPrimitive(recipient)) })
        if (noteId.isNotEmpty()) put("#e", buildJsonArray { add(JsonPrimitive(noteId)) })
        put("since", sinceSeconds - 60)
        put("limit", 50)
    }.toString()

    /**
     * True when [event] is a zap receipt for exactly [invoice]: its `bolt11`
     * tag is the invoice we paid. The receipt is signed by the provider that
     * issued that invoice, so it proves this payment, not some other zap.
     */
    fun receiptPaysInvoice(event: JsonObject, invoice: String): Boolean {
        if ((event["kind"] as? JsonPrimitive)?.intOrNull != 9735) return false
        val tags = event["tags"] as? JsonArray ?: return false
        return tags.any { tag ->
            val t = tag as? JsonArray ?: return@any false
            t.size >= 2 &&
                (t[0] as? JsonPrimitive)?.content == "bolt11" &&
                (t[1] as? JsonPrimitive)?.content.equals(invoice, ignoreCase = true)
        }
    }
}

/**
 * Zaps waiting on their wallet or receipt, by note (or `p:<pubkey>` for a
 * profile zap). A new zap on a pending note is held once with a question; the
 * same zap tapped again within [CONFIRM_MS] goes through.
 */
class PendingZaps(private val now: () -> Long = { System.currentTimeMillis() }) {
    private val pending = ConcurrentHashMap<String, Long>()
    private val asked = ConcurrentHashMap<String, Long>()
    /**
     * Zaps whose wallet hasn't answered yet. They stay pending however long
     * that takes: a Cashu pay (recover, a quote per mint, melt) can outlast
     * [PENDING_MS], and a second tap then must still be asked first.
     */
    private val paying = ConcurrentHashMap<String, Int>()

    private fun live(key: String, t: Long): Boolean =
        (paying[key] ?: 0) > 0 || pending[key]?.let { t - it <= PENDING_MS } == true

    /** True when the zap should go ahead; false means "ask first" (the caller says so and stops). */
    fun mayZap(key: String): Boolean {
        val t = now()
        if (!live(key, t)) {
            pending.remove(key)
            return true
        }
        val askedAt = asked[key]
        if (askedAt != null && t - askedAt <= CONFIRM_MS) {
            asked.remove(key)
            return true
        }
        asked[key] = t
        return false
    }

    fun begin(key: String) {
        pending[key] = now()
        paying.merge(key, 1, Int::plus)
        asked.remove(key)
    }

    /** The wallet answered (or gave up): the pending window runs from now. */
    fun answered(key: String) {
        // Counted per zap: a second confirmed tap on the same note stays
        // pending when the first one's wallet answers.
        if (paying[key] == null) return
        paying.computeIfPresent(key) { _, n -> (n - 1).takeIf { it > 0 } }
        pending[key] = now()
    }

    /** The zap is settled. Call after [answered]; another zap still paying on the key stays pending. */
    fun end(key: String) {
        pending.remove(key)
    }

    fun isPending(key: String): Boolean = live(key, now())

    companion object {
        /** A zap counts as pending for the wallet wait plus the receipt watch. */
        const val PENDING_MS = ZapConfirm.WALLET_WAIT_MS + ZapConfirm.RECEIPT_WATCH_MS
        /** A second tap within this long after the question sends another zap. */
        const val CONFIRM_MS = 15_000L

        fun key(noteId: String, recipient: String): String = noteId.ifEmpty { "p:$recipient" }
    }
}
