package com.nostrvault.service

import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.put
import kotlinx.serialization.json.Json
import java.security.MessageDigest
import java.security.SecureRandom
import java.util.Base64
import javax.crypto.Cipher
import javax.crypto.spec.GCMParameterSpec
import javax.crypto.spec.SecretKeySpec

/**
 * A photo in a DM as a NIP-17 kind 15 file message (DM privacy, Tron 2026-11-14). Port of web
 * `web-vault/src/net/dm-file.js` (#2075); both are checked against docs/DM_FILE_VECTORS.json.
 *
 * A plain photo link in a DM is public: anyone with the link sees the photo. So the file is
 * encrypted with a fresh AES-256-GCM key before it goes up; the server holds only ciphertext,
 * named by its hash (the x tag), and the key and nonce travel inside the sealed message.
 *
 * On this device a file message is kept as its link with what opens it in the fragment
 * ("<url>#nv-dm=<base64url JSON {k,n,x,m}>"), the same text the web keeps, so the thread, the
 * inbox and the saved conversations carry it as an ordinary message. A fragment is never sent in
 * a request; [DMFileLoader] fetches the ciphertext, checks its hash, and decrypts.
 */
object DMFile {
    const val MARK = "#nv-dm="
    /**
     * The most one encrypted file may be, as the web (dm-file.js MAX_FILE): 100 MB, room for a
     * compressed video (Logen 2026-11-15).
     */
    const val MAX_FILE = 100L * 1024 * 1024
    const val ALGORITHM = "aes-gcm"

    private val HEX64 = Regex("^[0-9a-f]{64}$")
    /** 12 bytes (ours, and GCM's usual) or 16 (some other NIP-17 apps). */
    private val NONCE = Regex("^(?:[0-9a-f]{24}|[0-9a-f]{32})$")
    private val MIME = Regex("^[a-z]+/[a-z0-9.+-]+$", RegexOption.IGNORE_CASE)
    private val LINK = Regex("^https://[^\\s#]+#nv-dm=[A-Za-z0-9_-]+$")
    private val BARE_HTTPS = Regex("^https://[^\\s#]+$")
    private val random = SecureRandom()
    private val json = Json { ignoreUnknownKeys = true }

    /** An encrypted file: hex [key] and [nonce], [x] = sha256 of [cipher], [ox] = sha256 of the original. */
    class Encrypted(val cipher: ByteArray, val key: String, val nonce: String, val x: String, val ox: String)

    /** What opens a kept link. */
    data class Link(val url: String, val key: String, val nonce: String, val x: String?, val mime: String, val ox: String? = null, val size: Long? = null)

    /** A kind 15 rumor's content and tags (after the p tag), and [shown], its link for this device. */
    data class Message(val content: String, val tags: List<List<String>>, val shown: String)

    class Refused(message: String) : Exception(message)

    /** Encrypt [plain] with a fresh 256-bit key and 96-bit nonce. [key]/[nonce] are for tests only. */
    fun encrypt(plain: ByteArray, key: ByteArray? = null, nonce: ByteArray? = null): Encrypted {
        val raw = key ?: ByteArray(32).also { random.nextBytes(it) }
        val iv = nonce ?: ByteArray(12).also { random.nextBytes(it) }
        val c = Cipher.getInstance("AES/GCM/NoPadding")
        c.init(Cipher.ENCRYPT_MODE, SecretKeySpec(raw, "AES"), GCMParameterSpec(128, iv))
        val cipher = c.doFinal(plain)
        return Encrypted(cipher, raw.hex(), iv.hex(), sha256Hex(cipher), sha256Hex(plain))
    }

    /**
     * The original bytes. Refuses (throws [Refused]) when [cipher] isn't the file named by [x]
     * (when given), doesn't open with the key, or opens to something other than [ox] (when given).
     */
    fun decrypt(cipher: ByteArray, key: String, nonce: String, x: String?, ox: String? = null): ByteArray {
        if (!HEX64.matches(key)) throw Refused("the key is not 32 bytes")
        if (!Regex("^(?:[0-9a-f]{2})+$").matches(nonce)) throw Refused("bad nonce")
        if (x != null && sha256Hex(cipher) != x) throw Refused("the file was changed on the server")
        val plain = try {
            val c = Cipher.getInstance("AES/GCM/NoPadding")
            c.init(Cipher.DECRYPT_MODE, SecretKeySpec(key.unhex(), "AES"), GCMParameterSpec(128, nonce.unhex()))
            c.doFinal(cipher)
        } catch (e: Exception) {
            throw Refused("the file doesn't open with its key")
        }
        if (ox != null && sha256Hex(plain) != ox) throw Refused("the file isn't the one that was sent")
        return plain
    }

    /**
     * "<url>#nv-dm=…": the message as this device keeps and shows it. Same JSON as the web (k, n, x, m),
     * plus o (the ox tag) when known, so a read can check the opened file too (the web ignores it),
     * and s (the size tag, encrypted bytes) when known, so a video shows its size before it loads.
     */
    fun fileLink(url: String, key: String, nonce: String, x: String?, mime: String?, ox: String? = null, size: Long? = null): String {
        val d = buildJsonObject {
            put("k", key)
            put("n", nonce)
            if (x != null) put("x", x)
            if (mime != null) put("m", mime)
            if (ox != null) put("o", ox)
            if (size != null) put("s", size)
        }
        val b64 = Base64.getUrlEncoder().withoutPadding().encodeToString(d.toString().toByteArray(Charsets.UTF_8))
        return "$url$MARK$b64"
    }

    fun isFileLink(s: String?): Boolean = s != null && LINK.matches(s)

    /** A kept file link whose file is a video (its type, from the file-type tag, starts with "video/"). */
    fun isVideoLink(s: String?): Boolean = parseFileLink(s?.trim())?.mime?.lowercase()?.startsWith("video/") == true

    fun parseFileLink(s: String?): Link? {
        if (s == null || !isFileLink(s)) return null
        val i = s.indexOf(MARK)
        return try {
            val text = String(Base64.getUrlDecoder().decode(s.substring(i + MARK.length)), Charsets.UTF_8)
            val d = json.parseToJsonElement(text) as? JsonObject ?: return null
            fun str(k: String) = (d[k] as? JsonPrimitive)?.takeIf { it.isString }?.content
            val k = str("k") ?: return null
            val n = str("n") ?: return null
            val x = str("x")
            val o = str("o")
            if (!HEX64.matches(k) || !NONCE.matches(n) || (x != null && !HEX64.matches(x)) || (o != null && !HEX64.matches(o))) return null
            val m = str("m")?.takeIf { MIME.matches(it) } ?: "application/octet-stream"
            val size = (d["s"] as? JsonPrimitive)?.takeIf { !it.isString }?.content?.toLongOrNull()?.takeIf { it in 1..MAX_FILE }
            Link(s.substring(0, i), k, n, x, m, o, size)
        } catch (e: Exception) {
            null
        }
    }

    /** The kind 15 tags for an uploaded ciphertext, in the web's order (dm-file.js fileMessage). */
    fun fileMessage(url: String, enc: Encrypted, mime: String?, dim: String? = null): Message {
        val type = mime?.takeIf { it.isNotEmpty() } ?: "application/octet-stream"
        val tags = mutableListOf(
            listOf("file-type", type),
            listOf("encryption-algorithm", ALGORITHM),
            listOf("decryption-key", enc.key),
            listOf("decryption-nonce", enc.nonce),
            listOf("x", enc.x),
            listOf("ox", enc.ox),
            listOf("size", enc.cipher.size.toString()),
        )
        if (dim != null) tags.add(listOf("dim", dim))
        return Message(url, tags, fileLink(url, enc.key, enc.nonce, enc.x, type, enc.ox, enc.cipher.size.toLong()))
    }

    /**
     * A received kind 15 rumor as this device keeps it: its link with what opens it; the bare link
     * when it isn't encrypted the way this reads (it then shows as an old photo link would); null
     * when its content isn't an https URL (not a message).
     */
    fun contentOf(rumor: JsonObject): String? {
        val url = (rumor["content"] as? JsonPrimitive)?.takeIf { it.isString }?.content?.trim() ?: return null
        if (!BARE_HTTPS.matches(url)) return null
        val tags = (rumor["tags"] as? JsonArray).orEmpty().mapNotNull { t ->
            (t as? JsonArray)?.map { (it as? JsonPrimitive)?.takeIf { p -> p.isString }?.content.orEmpty() }
        }
        fun tag(k: String) = tags.firstOrNull { it.size >= 2 && it[0] == k }?.get(1)
        val alg = tag("encryption-algorithm").orEmpty().lowercase()
        val key = tag("decryption-key").orEmpty().lowercase()
        val nonce = tag("decryption-nonce").orEmpty().lowercase()
        val x = tag("x").orEmpty().lowercase()
        val ox = tag("ox").orEmpty().lowercase()
        val size = tag("size")?.toLongOrNull()?.takeIf { it in 1..MAX_FILE }
        if (alg != ALGORITHM || !HEX64.matches(key) || !NONCE.matches(nonce)) return url
        val type = tag("file-type")?.takeIf { MIME.matches(it) }
        return fileLink(url, key, nonce, x.takeIf { HEX64.matches(it) }, type, ox.takeIf { HEX64.matches(it) }, size)
    }

    /** The inbox row / notification line for a kept file link, null for any other message. */
    fun previewOf(content: String?): String? = when {
        !isFileLink(content?.trim()) -> null
        isVideoLink(content) -> "Video"
        else -> "Photo"
    }

    fun sha256Hex(b: ByteArray): String = MessageDigest.getInstance("SHA-256").digest(b).hex()

    private fun ByteArray.hex(): String = joinToString("") { "%02x".format(it) }
    private fun String.unhex(): ByteArray = ByteArray(length / 2) { substring(it * 2, it * 2 + 2).toInt(16).toByte() }
}
