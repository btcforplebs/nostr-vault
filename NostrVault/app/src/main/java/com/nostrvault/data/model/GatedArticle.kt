package com.nostrvault.data.model

import java.net.URI
import java.nio.ByteBuffer
import javax.crypto.Cipher
import javax.crypto.spec.GCMParameterSpec
import javax.crypto.spec.SecretKeySpec

/**
 * A long-form article whose body is sold for a zap ("zap N sats to unlock").
 *
 * There is no merged NIP for this. The event carries
 * `["encrypted", "aes-256-gcm", <base64>, <key URL>]` and
 * `["price", "42", "SATS"]`; `content` is only a teaser plus a link. Payment
 * is an ordinary NIP-57 zap receipt carrying the article's `a` coordinate
 * from the reader's pubkey, so a zap from any client counts. The key comes
 * from the key URL behind NIP-98 HTTP auth: the server answers 402 until the
 * receipts cover the price, then returns the AES key as 64 hex characters.
 * The base64 blob is WebCrypto's layout: 12-byte IV, ciphertext, 16-byte tag.
 *
 * Nostr Vault unlocks (asks for the key, and pays) only Fanfares articles
 * ([isFanfares], owner decision 2026-10-20). Any other gated article stays
 * locked; a key stored by an earlier version still opens it.
 */
data class GatedArticle(
    /** Base64 of IV ‖ ciphertext ‖ tag. */
    val ciphertext: String,
    /** Where the author's tag says the key lives; also the `u` the NIP-98 event names. */
    val keyUrl: String,
    val priceSats: Int,
    val shares: List<Share>,
) {
    data class Share(val pubkey: String, val relay: String?, val sats: Int)

    /** What paying every share costs: each share rounds up, so this can be a little over [priceSats]. */
    val totalSats: Int get() = shares.sumOf { it.sats }

    /**
     * Whether the app may pay this price itself. Rounding each share up costs
     * at most a sat per share, so a price split [MAX_SHARES] ways or fewer
     * stays within [MAX_SHARES] sats of the price; an article split more ways
     * (500 `zap` tags on a 42-sat price is 500 sats in 500 payments) is not
     * paid here.
     */
    val payableInApp: Boolean
        get() = shares.size <= MAX_SHARES && totalSats <= priceSats + MAX_SHARES

    /** Relays the author named in their `zap` tags, where the key server finds the receipt. */
    val receiptRelays: List<String>
        get() = shares.mapNotNull { it.relay }.distinctBy { it.lowercase() }

    /**
     * Whether the key lives on Fanfares (fanfares.live or fanfares.io, or a
     * subdomain such as api.fanfares.live). Only these are unlocked in the app.
     */
    val isFanfares: Boolean
        get() = isFanfaresHost(runCatching { URI(keyUrl) }.getOrNull()?.host)

    /**
     * Where to send the key request. Fanfares' tag names its backend, which
     * wants a private API key; its web app reaches it through a public proxy,
     * and so must we. The NIP-98 `u` still names the tag's URL.
     */
    val requestUrl: String
        get() {
            val uri = runCatching { URI(keyUrl) }.getOrNull() ?: return keyUrl
            return if (uri.host?.lowercase() == "api.fanfares.live") "https://fanfares.io/api" + uri.rawPath else keyUrl
        }

    /** Tags of the NIP-98 (kind 27235) event that asks for the key; its content is the naddr. */
    val httpAuthTags: List<List<String>>
        get() = listOf(listOf("u", keyUrl), listOf("method", "GET"))

    /**
     * Decrypts the body with the key the server returned. Null when the key
     * isn't 32 bytes of hex or doesn't open the box: a wrong key and a
     * corrupted body look the same, and both mean "show nothing".
     */
    fun decrypt(keyHex: String): String? {
        val hex = keyHex.trim()
        if (hex.length != 64) return null
        val key = hexToBytes(hex) ?: return null
        val blob = runCatching { java.util.Base64.getMimeDecoder().decode(ciphertext) }.getOrNull() ?: return null
        if (blob.size <= 12 + 16) return null
        return try {
            val cipher = Cipher.getInstance("AES/GCM/NoPadding")
            cipher.init(Cipher.DECRYPT_MODE, SecretKeySpec(key, "AES"), GCMParameterSpec(128, blob, 0, 12))
            // JCE wants the tag appended, which is already how the blob is laid out.
            String(cipher.doFinal(blob, 12, blob.size - 12), Charsets.UTF_8)
        } catch (e: Exception) {
            null
        }
    }

    companion object {
        /** Null for an ordinary article, or a gated one we can't act on (no https key URL, other algorithm, no sats price). */
        fun from(kind: Int, pubkey: String, tags: List<List<String>>): GatedArticle? {
            if (kind != ArticleMeta.KIND) return null
            val enc = tags.firstOrNull { it.firstOrNull() == "encrypted" } ?: return null
            if (enc.size < 4 || !enc[1].equals("aes-256-gcm", ignoreCase = true) || enc[2].isEmpty()) return null
            val keyUrl = enc[3]
            if (!keyUrl.startsWith("https://") || runCatching { URI(keyUrl) }.getOrNull()?.host == null) return null

            val priceTag = tags.firstOrNull { it.firstOrNull() == "price" && it.size >= 2 } ?: return null
            val amount = priceTag[1].trim().toIntOrNull()?.takeIf { it > 0 } ?: return null
            // Only sats are something a zap can pay; a fiat price stays a link out.
            val currency = if (priceTag.size >= 3) priceTag[2].uppercase() else "SATS"
            if (currency != "SATS" && currency != "SAT") return null

            return GatedArticle(enc[2], keyUrl, amount, split(amount, pubkey, tags))
        }

        fun from(note: FeedNote): GatedArticle? = from(note.kind, note.pubkey, note.tags)

        /** The most shares (and so payments, and sats over the price) the app pays for one article. */
        const val MAX_SHARES = 10

        private val FANFARES_DOMAINS = listOf("fanfares.live", "fanfares.io")

        /** fanfares.live, fanfares.io, or a subdomain of either; never a look-alike such as notfanfares.io. */
        fun isFanfaresHost(host: String?): Boolean {
            val h = host?.lowercase()?.trimEnd('.') ?: return false
            return FANFARES_DOMAINS.any { h == it || h.endsWith(".$it") }
        }

        /**
         * Splits the price across the event's NIP-57 `zap` tags by weight, the
         * way Fanfares' own check does: a recipient listed twice has its weights
         * summed, no `zap` tag means the author takes it all, each share rounds up.
         */
        fun split(price: Int, authorPubkey: String, tags: List<List<String>>): List<Share> {
            val order = mutableListOf<String>()
            val weights = HashMap<String, Int>()
            val relays = HashMap<String, String>()
            for (tag in tags) {
                if (tag.firstOrNull() != "zap" || tag.size < 2) continue
                val pk = tag[1].lowercase()
                if (pk.length != 64 || !pk.all { it in '0'..'9' || it in 'a'..'f' }) continue
                // A missing, zero or unparseable weight reads as 1.
                val weight = if (tag.size >= 4) maxOf(tag[3].toIntOrNull() ?: 1, 1) else 1
                if (pk !in weights) order.add(pk)
                weights[pk] = (weights[pk] ?: 0) + weight
                if (pk !in relays && tag.size >= 3 && tag[2].isNotEmpty()) relays[pk] = tag[2]
            }
            val total = order.sumOf { weights[it] ?: 0 }
            if (total <= 0) return listOf(Share(authorPubkey, null, price))
            return order.map { pk ->
                val weight = weights[pk] ?: 1
                val sats = if (total == price) weight else Math.ceil(weight.toDouble() / total * price).toInt()
                Share(pk, relays[pk], sats)
            }
        }

        /**
         * The NIP-19 naddr TLV payload, entries in the order nostr-tools writes
         * them (kind, author, relay, d), so the bech32 string we sign is
         * byte-identical to the one Fanfares' own site signs.
         */
        fun naddrTlv(identifier: String, relay: String?, pubkey: String, kind: Int): ByteArray? {
            val author = hexToBytes(pubkey)?.takeIf { it.size == 32 } ?: return null
            fun entry(type: Int, value: ByteArray): ByteArray? =
                if (value.size > 255) null else byteArrayOf(type.toByte(), value.size.toByte()) + value
            val out = java.io.ByteArrayOutputStream()
            out.write(byteArrayOf(3, 4) + ByteBuffer.allocate(4).putInt(kind).array())
            out.write(byteArrayOf(2, 32) + author)
            if (!relay.isNullOrEmpty()) entry(1, relay.toByteArray())?.let { out.write(it) }
            out.write(entry(0, identifier.toByteArray()) ?: return null)
            return out.toByteArray()
        }

        internal fun hexToBytes(hex: String): ByteArray? {
            if (hex.length % 2 != 0) return null
            val out = ByteArray(hex.length / 2)
            for (i in out.indices) {
                val hi = Character.digit(hex[i * 2], 16)
                val lo = Character.digit(hex[i * 2 + 1], 16)
                if (hi < 0 || lo < 0) return null
                out[i] = (hi shl 4 or lo).toByte()
            }
            return out
        }
    }
}

/** The teaser a gated article ships in `content`, minus the "zap to unlock … <link>" line the lock card replaces. */
object GatedArticleTeaser {
    private fun ctaIndex(lines: List<String>) = lines.indexOfLast { it.contains("to unlock", ignoreCase = true) }

    fun strip(content: String): String {
        val lines = content.lines()
        val cta = ctaIndex(lines).takeIf { it >= 0 } ?: return content
        return lines.take(cta).joinToString("\n").trim()
    }

    /** What a preview should read from: the stripped teaser for a gated article, the body otherwise. */
    fun previewBody(note: FeedNote): String =
        if (GatedArticle.from(note) == null) note.content else strip(note.content)
}
