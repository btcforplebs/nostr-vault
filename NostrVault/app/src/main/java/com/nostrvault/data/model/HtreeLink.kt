package com.nostrvault.data.model

import java.security.MessageDigest
import java.util.concurrent.ConcurrentHashMap
import javax.crypto.Cipher
import javax.crypto.Mac
import javax.crypto.spec.GCMParameterSpec
import javax.crypto.spec.SecretKeySpec

/**
 * A hashtree (Iris) photo link: `htree://nhash1…/<name>`.
 *
 * The nhash carries the sha256 of an encrypted blob and the key that opens it
 * (hashtree c5e41a5 `docs/HTS-01.md`, `ts/packages/hashtree/src/{nhash,encryption,crypto}.ts`).
 * Phase 1 reads only what a photo up to 2 MiB is: one blob, CHK-encrypted,
 * where the key IS the sha256 of the plain file. So the link already names
 * the photo the way Blossom does, and the vault keeps it under [plainSha256].
 *
 * nhash: bech32 "nhash", TLV 0 = blob hash (32), 5 = key (33 bytes with a
 * suite byte, 1 = chk-v1; 32 bytes = legacy CHK). rnd-v1 keys (suite 2, no
 * plain hash in the link) and links without a key are not read: they stay text.
 * Decrypt: AES-256-GCM, key = HKDF-SHA256(ikm = plain hash, salt
 * "hashtree-chk", info "encryption-key"), all-zero 12-byte nonce, 16-byte tag
 * at the end. Web: `web-vault/src/net/htree.js` (#2508). Fixture:
 * `docs/HTREE_VECTORS.json`.
 */
data class HtreeLink(
    /** sha256 hex of the encrypted blob: the name servers know it by. */
    val blobHash: String,
    /** The 32-byte CHK key, which is the plain file's sha256. */
    val chk: ByteArray,
    /** File name hint from the path ("1692-01.jpg"), possibly empty. */
    val name: String,
    /** Lowercase extension of [name], possibly empty. */
    val ext: String,
) {
    /** The plain photo's sha256: its Blossom name, and the vault's. */
    val plainSha256: String get() = chk.toHex()

    override fun equals(other: Any?): Boolean =
        other is HtreeLink && other.blobHash == blobHash && other.chk.contentEquals(chk) && other.name == name
    override fun hashCode(): Int = blobHash.hashCode()

    /** `<server>/<blobHash>` for each of Iris, the author's list, then ours: https, public, once each, [MAX_SERVERS] at most. */
    fun candidates(authorServers: List<String>, ownServers: List<String>): List<String> =
        servers(authorServers, ownServers).map { "$it/$blobHash" }

    companion object {
        const val SCHEME = "htree"
        /** Iris's upload server: every htree photo seen so far is only there. */
        val IRIS_SERVERS = listOf("https://upload.iris.to")
        const val MAX_SERVERS = 8
        /** Phase 1 reads one blob: a photo up to 2 MiB, plus the GCM tag. */
        const val MAX_PLAIN_BYTES = 2L * 1024 * 1024
        const val MAX_BLOB_BYTES = MAX_PLAIN_BYTES + 16

        /** Where a note's text has one: the link and its file name, up to the next space. */
        val TOKEN = Regex("""htree://nhash1[02-9ac-hj-np-zA-Z]{20,}(?:/[^\s<>"]*)?""")
        private val LINK = Regex("""^htree://(nhash1[02-9ac-hj-np-zA-Z]+)(?:/([^\s<>"]*))?$""", RegexOption.IGNORE_CASE)
        private val PICTURE_EXTENSIONS = setOf("jpg", "jpeg", "png", "gif", "webp", "avif")

        fun isUri(url: String): Boolean = url.startsWith("$SCHEME://", ignoreCase = true)

        /** Null for anything phase 1 can't show. */
        fun parse(raw: String): HtreeLink? {
            val m = LINK.matchEntire(raw.trim()) ?: return null
            val nhash = decodeNhash(m.groupValues[1]) ?: return null
            val key = nhash.second ?: return null
            val chk = when {
                key.size == 32 -> key
                key.size == 33 && key[0] == 1.toByte() -> key.copyOfRange(1, 33)
                else -> return null
            }
            val path = m.groupValues[2].substringBefore('?').substringBefore('#')
            val name = runCatching { java.net.URLDecoder.decode(path.replace("+", "%2B"), "UTF-8") }.getOrDefault(path)
            val ext = Regex("""\.([A-Za-z0-9]{1,10})$""").find(name)?.groupValues?.get(1)?.lowercase().orEmpty()
            return HtreeLink(nhash.first, chk, name, ext)
        }

        /** A link the note's media carousel draws: one phase 1 reads, named as a picture or not named at all. */
        fun isPhotoLink(raw: String): Boolean = parse(raw)?.let { it.ext.isEmpty() || it.ext in PICTURE_EXTENSIONS } == true

        /** (blob hash hex, key bytes or null), or null when it isn't an nhash. */
        fun decodeNhash(code: String): Pair<String, ByteArray?>? {
            val data = bech32Decode(code.lowercase(), "nhash") ?: return null
            if (data.size == 32) return data.toHex() to null
            var hash: String? = null
            var key: ByteArray? = null
            var at = 0
            while (at < data.size) {
                if (at + 2 > data.size) return null
                val t = data[at].toInt() and 0xff
                val l = data[at + 1].toInt() and 0xff
                at += 2
                if (at + l > data.size) return null
                val v = data.copyOfRange(at, at + l)
                at += l
                if (t == 0 && l == 32 && hash == null) hash = v.toHex()
                if (t == 5 && key == null) key = v
            }
            return hash?.let { it to key }
        }

        /** CHK decrypt: the plain bytes, or null when the tag doesn't check. */
        fun decryptChk(cipher: ByteArray, chk: ByteArray): ByteArray? {
            if (cipher.size < 16 || chk.size != 32) return null
            return try {
                val key = hkdfSha256(chk, "hashtree-chk".toByteArray(), "encryption-key".toByteArray(), 32)
                val c = Cipher.getInstance("AES/GCM/NoPadding")
                c.init(Cipher.DECRYPT_MODE, SecretKeySpec(key, "AES"), GCMParameterSpec(128, ByteArray(12)))
                c.doFinal(cipher)
            } catch (e: Exception) {
                null
            }
        }

        /**
         * The checked photo from one server's answer: blob hash, decrypt, plain
         * hash, picture. Null at the first check that fails.
         */
        fun open(link: HtreeLink, blob: ByteArray): Opened? {
            if (blob.size > MAX_BLOB_BYTES || sha256Hex(blob) != link.blobHash) return null
            val plain = decryptChk(blob, link.chk) ?: return null
            if (sha256Hex(plain) != link.plainSha256) return null
            val mime = sniffImage(plain) ?: return null
            return Opened(plain, mime)
        }

        class Opened(val bytes: ByteArray, val mime: String)

        /** "image/…" from the file's first bytes, or null: only pictures are drawn, whatever the name says. */
        fun sniffImage(b: ByteArray): String? {
            fun u(i: Int) = b[i].toInt() and 0xff
            fun ascii(from: Int, to: Int) = String(b, from, to - from, Charsets.ISO_8859_1)
            return when {
                b.size >= 3 && u(0) == 0xff && u(1) == 0xd8 && u(2) == 0xff -> "image/jpeg"
                b.size >= 8 && b.copyOfRange(0, 8).toHex() == "89504e470d0a1a0a" -> "image/png"
                b.size >= 6 && (ascii(0, 6) == "GIF87a" || ascii(0, 6) == "GIF89a") -> "image/gif"
                b.size >= 12 && ascii(0, 4) == "RIFF" && ascii(8, 12) == "WEBP" -> "image/webp"
                b.size >= 12 && ascii(4, 8) == "ftyp" && (ascii(8, 12) == "avif" || ascii(8, 12) == "avis") -> "image/avif"
                else -> null
            }
        }

        /** Iris, the author's servers, then ours, as https origins: public, once each, [MAX_SERVERS] at most. */
        fun servers(authorServers: List<String>, ownServers: List<String>): List<String> =
            (IRIS_SERVERS + authorServers + ownServers).mapNotNull(BlossomUri::serverOrigin)
                .distinctBy { it.lowercase() }.take(MAX_SERVERS)

        fun sha256Hex(bytes: ByteArray): String = MessageDigest.getInstance("SHA-256").digest(bytes).toHex()

        // Note authors by blob hash, for the author's 10063 when the link is drawn.
        private val noteAuthors = ConcurrentHashMap<String, String>()
        private const val MAX_REMEMBERED_AUTHORS = 4_000

        /** Remember who posted these links. */
        fun register(urls: List<String>, author: String) {
            for (url in urls) {
                val link = if (isUri(url)) parse(url) ?: continue else continue
                if (noteAuthors.size >= MAX_REMEMBERED_AUTHORS) noteAuthors.clear()
                noteAuthors.putIfAbsent(link.blobHash, author)
            }
        }

        fun noteAuthor(blobHash: String): String? = noteAuthors[blobHash]

        private fun hkdfSha256(ikm: ByteArray, salt: ByteArray, info: ByteArray, length: Int): ByteArray {
            val mac = Mac.getInstance("HmacSHA256")
            mac.init(SecretKeySpec(salt, "HmacSHA256"))
            val prk = mac.doFinal(ikm)
            mac.init(SecretKeySpec(prk, "HmacSHA256"))
            val out = java.io.ByteArrayOutputStream()
            var t = ByteArray(0)
            var i = 1
            while (out.size() < length) {
                mac.update(t); mac.update(info); mac.update(i.toByte())
                t = mac.doFinal()
                out.write(t)
                i++
            }
            return out.toByteArray().copyOf(length)
        }

        private const val CHARSET = "qpzry9x8gf2tvdw0s3jn54khce6mua7l"

        /** BIP-173 bech32 (checksum checked) with the expected [hrp]; the data bytes, or null. */
        private fun bech32Decode(s: String, hrp: String): ByteArray? {
            val pos = s.lastIndexOf('1')
            if (pos < 1 || s.substring(0, pos) != hrp || s.length - pos - 1 < 6) return null
            val words = s.substring(pos + 1).map { CHARSET.indexOf(it) }
            if (words.any { it < 0 }) return null
            val expanded = hrp.map { it.code shr 5 } + 0 + hrp.map { it.code and 31 }
            if (polymod(expanded + words) != 1) return null
            var acc = 0
            var bits = 0
            val out = java.io.ByteArrayOutputStream()
            for (w in words.dropLast(6)) {
                acc = (acc shl 5) or w
                bits += 5
                if (bits >= 8) {
                    bits -= 8
                    out.write((acc shr bits) and 0xff)
                }
            }
            if (bits >= 5 || ((acc shl (8 - bits)) and 0xff) != 0) return null
            return out.toByteArray()
        }

        private fun polymod(values: List<Int>): Int {
            val gen = intArrayOf(0x3b6a57b2, 0x26508e6d, 0x1ea119fa, 0x3d4233dd, 0x2a1462b3)
            var chk = 1
            for (v in values) {
                val top = chk ushr 25
                chk = ((chk and 0x1ffffff) shl 5) xor v
                for (i in 0 until 5) if ((top shr i) and 1 == 1) chk = chk xor gen[i]
            }
            return chk
        }
    }
}

private fun ByteArray.toHex(): String = joinToString("") { "%02x".format(it) }
