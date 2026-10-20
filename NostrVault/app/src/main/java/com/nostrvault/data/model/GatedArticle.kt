package com.nostrvault.data.model

import java.net.URI
import javax.crypto.Cipher
import javax.crypto.spec.GCMParameterSpec
import javax.crypto.spec.SecretKeySpec

/**
 * A long-form article whose body is sold for a zap ("zap N sats to unlock").
 *
 * There is no merged NIP for this. The event carries
 * `["encrypted", "aes-256-gcm", <base64>, <key URL>]` and
 * `["price", "42", "SATS"]`; `content` is only a teaser plus a link. Nostr
 * Vault shows it locked and does not unlock it; a key stored by an earlier
 * version still opens it. The base64 blob is WebCrypto's layout: 12-byte IV,
 * ciphertext, 16-byte tag.
 */
data class GatedArticle(
    /** Base64 of IV ‖ ciphertext ‖ tag. */
    val ciphertext: String,
    /** Where the author's tag says the key lives. */
    val keyUrl: String,
    val priceSats: Int,
) {
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

            return GatedArticle(enc[2], keyUrl, amount)
        }

        fun from(note: FeedNote): GatedArticle? = from(note.kind, note.pubkey, note.tags)

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
