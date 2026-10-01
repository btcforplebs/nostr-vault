package com.nostrvault.util

import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.doubleOrNull
import kotlinx.serialization.json.longOrNull

/**
 * Who a zap in the wallet history came from (or went to) and which post it
 * was for.
 *
 * A wallet's history only knows amounts and invoices. The people and the
 * post live in the NIP-57 zap request (kind 9734): it is the invoice's
 * description, so some wallets hand it back as the transaction description,
 * and it is embedded in the public zap receipt (kind 9735) that also
 * carries the paid bolt11. Either source gives the same [ZapDetail].
 *
 * Plain Kotlin, no Android types, so it runs under JVM unit tests.
 * Port of iOS ZapHistory.swift.
 */
data class ZapDetail(
    /**
     * Whoever sent the zap — the zap request's author. For an anonymous zap
     * this is a throwaway key, so [isAnonymous] must be checked first.
     */
    val senderPubkey: String,
    /** Whoever was zapped (the request's `p` tag). */
    val recipientPubkey: String?,
    /** The post that was zapped (the request's `e` tag), if it was a post rather than a profile. */
    val postId: String?,
    /** What the sender wrote with the zap. */
    val comment: String?,
    val isAnonymous: Boolean,
    /**
     * The zap request exactly as it arrived, so its signature can be checked
     * before any of the above is believed: the fields are whatever its author
     * wrote, and only a valid signature makes the author who it says.
     */
    val requestJson: String? = null,
) {
    /** The person on the other side of the payment from `me`. */
    fun counterparty(me: String, direction: WalletTransaction.Direction): String? = when (direction) {
        WalletTransaction.Direction.INCOMING -> if (isAnonymous) null else senderPubkey
        WalletTransaction.Direction.OUTGOING -> recipientPubkey
    }

    companion object {
        private val json = Json { ignoreUnknownKeys = true }

        /**
         * Reads a zap request (kind 9734) given as JSON text. Returns null for
         * anything else — which is how a plain invoice description is told apart.
         */
        fun fromZapRequest(text: String): ZapDetail? {
            val trimmed = text.trim()
            if (!trimmed.startsWith("{")) return null
            val obj = runCatching { json.parseToJsonElement(trimmed) as? JsonObject }.getOrNull() ?: return null
            return fromZapRequest(obj)?.copy(requestJson = trimmed)
        }

        fun fromZapRequest(obj: JsonObject): ZapDetail? {
            if (intValue(obj["kind"]) != 9734L) return null
            val pubkey = (obj["pubkey"] as? JsonPrimitive)?.takeIf { it.isString }?.content
            if (pubkey.isNullOrEmpty()) return null
            val tags = parseTags(obj["tags"])
            val comment = (obj["content"] as? JsonPrimitive)?.takeIf { it.isString }?.content?.trim()
            return ZapDetail(
                senderPubkey = pubkey,
                recipientPubkey = firstTag("p", tags),
                postId = firstTag("e", tags),
                comment = comment?.ifEmpty { null },
                isAnonymous = tags.any { it.firstOrNull() == "anon" },
            )
        }

        /** A Nostr `tags` array; entries that are not string arrays are skipped. */
        fun parseTags(element: JsonElement?): List<List<String>> {
            val array = element as? JsonArray ?: return emptyList()
            return array.mapNotNull { tag ->
                (tag as? JsonArray)?.map { (it as? JsonPrimitive)?.takeIf { p -> p.isString }?.content ?: return@mapNotNull null }
            }
        }

        private fun firstTag(name: String, tags: List<List<String>>): String? =
            tags.firstOrNull { it.size >= 2 && it[0] == name && it[1].isNotEmpty() }?.get(1)

        private fun intValue(element: JsonElement?): Long? {
            val p = element as? JsonPrimitive ?: return null
            if (p.isString) return null
            return p.longOrNull ?: p.doubleOrNull?.takeIf { it % 1.0 == 0.0 }?.toLong()
        }
    }
}

/** A zap receipt (kind 9735) reduced to what history matching needs. */
data class ZapReceipt(
    val paymentHash: String?,
    val bolt11: String,
    val detail: ZapDetail,
) {
    companion object {
        /**
         * From a receipt's tags: `bolt11` is the paid invoice, `description`
         * the zap request. A receipt missing either is unusable.
         */
        fun fromTags(tags: List<List<String>>): ZapReceipt? {
            fun tag(name: String) = tags.firstOrNull { it.size >= 2 && it[0] == name }?.get(1)
            val bolt11 = tag("bolt11")?.lowercase() ?: return null
            val description = tag("description") ?: return null
            val detail = ZapDetail.fromZapRequest(description) ?: return null
            return ZapReceipt(Bolt11.paymentHash(bolt11), bolt11, detail)
        }

        /**
         * Pairs each transaction with its receipt: by payment hash when both
         * sides have one, otherwise by the invoice text itself. Keyed by
         * transaction id.
         *
         * Two receipts that tell different stories about the same payment mean
         * at least one is forged, and there is no telling which: that payment
         * gets neither.
         */
        fun match(transactions: List<WalletTransaction>, receipts: List<ZapReceipt>): Map<String, ZapDetail> {
            val byHash = HashMap<String, ZapDetail>()
            val byInvoice = HashMap<String, ZapDetail>()
            val conflictedHashes = HashSet<String>()
            val conflictedInvoices = HashSet<String>()
            for (r in receipts) {
                r.paymentHash?.let { h ->
                    if (byHash[h]?.let { it != r.detail } == true) conflictedHashes.add(h)
                    byHash[h] = r.detail
                }
                if (byInvoice[r.bolt11]?.let { it != r.detail } == true) conflictedInvoices.add(r.bolt11)
                byInvoice[r.bolt11] = r.detail
            }
            val out = LinkedHashMap<String, ZapDetail>()
            for (tx in transactions) {
                val hash = tx.paymentHash
                if (hash != null && hash in byHash) {
                    if (hash !in conflictedHashes) out[tx.id] = byHash.getValue(hash)
                    continue
                }
                val inv = tx.invoice?.lowercase() ?: continue
                if (inv !in conflictedInvoices) byInvoice[inv]?.let { out[tx.id] = it }
            }
            return out
        }
    }
}
