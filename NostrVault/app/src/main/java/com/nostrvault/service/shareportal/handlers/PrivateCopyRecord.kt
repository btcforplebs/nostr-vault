package com.nostrvault.service.shareportal.handlers

import com.nostrvault.shareportal.ShareIntent
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import java.security.MessageDigest
import java.security.SecureRandom
import javax.crypto.Cipher
import javax.crypto.spec.GCMParameterSpec
import javax.crypto.spec.SecretKeySpec

/**
 * A private copy (Share Portal, lane B): a file kept encrypted in the
 * person's own vault, findable again from any of their devices.
 *
 * - The file is sealed with AES-256-GCM under a fresh random key and nonce.
 *   The blob is `ciphertext ‖ 16-byte tag` (the nonce is kept in the
 *   record), so the vault only ever holds bytes nobody can read.
 * - The blob goes to this device's vault only: no outside Blossom server.
 * - The key lives in one NIP-78 record per copy (kind 30078), its content
 *   this [Record] as JSON, NIP-44 encrypted to the account's own key, sent
 *   to the vault only. The `d` tag is a random id, so the tags say nothing
 *   about the file.
 *
 * Pure, tested against the shared fixtures (`private-copy-cases.json`).
 * Twin: PrivateCopyRecord.swift.
 */
object PrivateCopyRecord {
    const val KIND = 30078
    const val D_PREFIX = "nv-private-copy:"
    const val ALGORITHM = "aes-256-gcm"
    /** A bigger file is refused before it is read: sealing happens in memory. */
    const val MAX_BYTES = 100_000_000

    data class Record(
        val name: String,
        val mime: String,
        /** Bytes of the file before sealing. */
        val size: Int,
        /** sha256 of the sealed blob: its name in the vault. */
        val x: String,
        /** sha256 of the file itself. */
        val ox: String,
        val key: String,
        val nonce: String,
        val source: String? = null,
        val title: String? = null,
        val savedAt: Long,
    )

    // ── Event ──

    fun dTag(id: String): String = D_PREFIX + id

    fun tags(id: String): List<List<String>> =
        listOf(listOf("d", dTag(id)), listOf("client", "Nostr Vault"), listOf("encryption", "nip44"))

    /** The same slot with nothing in it: the copy was deleted. */
    fun clearedTags(id: String): List<List<String>> = listOf(listOf("d", dTag(id)), listOf("deleted", "true"))

    /** The copy id of a private-copy event, or null when it is not one. */
    fun id(kind: Int, tags: List<List<String>>): String? {
        if (kind != KIND) return null
        val d = tags.firstOrNull { it.size >= 2 && it[0] == "d" }?.get(1) ?: return null
        if (!d.startsWith(D_PREFIX)) return null
        val id = d.removePrefix(D_PREFIX)
        return id.takeIf { ShareIntent.isValidId(it) }
    }

    fun isCleared(content: String, tags: List<List<String>>): Boolean =
        content.isBlank() || tags.any { it.size >= 2 && it[0] == "deleted" && it[1] == "true" }

    /** NIP-44 output is base64 of a version byte 2 and more; anything else is never published. */
    fun isCiphertext(s: String): Boolean {
        val data = runCatching { java.util.Base64.getDecoder().decode(s) }.getOrNull() ?: return false
        return data.size >= 99 && data[0].toInt() == 2
    }

    // ── Record JSON ──

    fun encode(r: Record): String {
        // Sorted keys, as the Swift twin writes them.
        val fields = sortedMapOf<String, JsonPrimitive>(
            "alg" to JsonPrimitive(ALGORITHM), "key" to JsonPrimitive(r.key), "mime" to JsonPrimitive(r.mime),
            "name" to JsonPrimitive(r.name), "nonce" to JsonPrimitive(r.nonce), "ox" to JsonPrimitive(r.ox),
            "saved_at" to JsonPrimitive(r.savedAt), "size" to JsonPrimitive(r.size), "v" to JsonPrimitive(1),
            "x" to JsonPrimitive(r.x),
        )
        r.source?.let { fields["source"] = JsonPrimitive(it) }
        r.title?.let { fields["title"] = JsonPrimitive(it) }
        return JsonObject(fields).toString()
    }

    /** Decodes and validates a decrypted record. Null for anything off. */
    fun decode(json: String): Record? {
        val d = runCatching { Json.parseToJsonElement(json) as? JsonObject }.getOrNull() ?: return null
        fun str(k: String): String? = (d[k] as? JsonPrimitive)?.takeIf { it.isString }?.content
        fun num(k: String): Long? = (d[k] as? JsonPrimitive)?.takeIf { !it.isString }?.content?.toDoubleOrNull()?.toLong()
        if (num("v") != 1L || str("alg") != ALGORITHM) return null
        val name = str("name")?.takeIf { ShareIntent.isValidFileName(it) } ?: return null
        val mime = str("mime")?.takeIf { it.isNotEmpty() && it.length <= 255 } ?: return null
        val size = num("size")?.takeIf { it in 0..MAX_BYTES.toLong() } ?: return null
        val x = str("x")?.takeIf { isHex(it, 64) } ?: return null
        val ox = str("ox")?.takeIf { isHex(it, 64) } ?: return null
        val key = str("key")?.takeIf { isHex(it, 64) } ?: return null
        val nonce = str("nonce")?.takeIf { isHex(it, 24) } ?: return null
        val savedAt = num("saved_at") ?: return null
        return Record(
            name = name, mime = mime, size = size.toInt(), x = x.lowercase(), ox = ox.lowercase(),
            key = key.lowercase(), nonce = nonce.lowercase(),
            source = str("source")?.let { ShareIntent.cap(it, ShareIntent.MAX_URL) },
            title = str("title")?.let { ShareIntent.cap(it, ShareIntent.MAX_TITLE) },
            savedAt = savedAt,
        )
    }

    // ── Sealing ──

    class Sealed(val blob: ByteArray, val key: String, val nonce: String, val x: String, val ox: String)

    private val random = SecureRandom()

    /** Seals [plain] under a new random key and nonce. */
    fun seal(plain: ByteArray): Sealed {
        val key = ByteArray(32).also { random.nextBytes(it) }
        val nonce = ByteArray(12).also { random.nextBytes(it) }
        return seal(plain, key, nonce)
    }

    /** Seals with a given key and nonce. For the fixtures; the app always uses [seal]. */
    fun seal(plain: ByteArray, key: ByteArray, nonce: ByteArray): Sealed {
        require(key.size == 32 && nonce.size == 12)
        val cipher = Cipher.getInstance("AES/GCM/NoPadding")
        cipher.init(Cipher.ENCRYPT_MODE, SecretKeySpec(key, "AES"), GCMParameterSpec(128, nonce))
        val blob = cipher.doFinal(plain) // ciphertext ‖ tag
        return Sealed(blob, hex(key), hex(nonce), sha256(blob), sha256(plain))
    }

    class OpenException(message: String) : Exception(message)

    /** The file back from its blob. Refuses a blob or file whose hash is not the record's. */
    fun open(blob: ByteArray, record: Record): ByteArray {
        if (sha256(blob) != record.x) throw OpenException("wrong blob")
        val key = unhex(record.key)
        val nonce = unhex(record.nonce)
        if (key == null || nonce == null || blob.size < 16) throw OpenException("bad record")
        val cipher = Cipher.getInstance("AES/GCM/NoPadding")
        cipher.init(Cipher.DECRYPT_MODE, SecretKeySpec(key, "AES"), GCMParameterSpec(128, nonce))
        val plain = try { cipher.doFinal(blob) } catch (e: Exception) { throw OpenException("doesn't open") }
        if (sha256(plain) != record.ox) throw OpenException("wrong file")
        return plain
    }

    // ── Hex ──

    fun sha256(data: ByteArray): String = hex(MessageDigest.getInstance("SHA-256").digest(data))

    fun hex(data: ByteArray): String = data.joinToString("") { "%02x".format(java.util.Locale.ROOT, it.toInt() and 0xff) }

    fun unhex(s: String): ByteArray? {
        if (s.length % 2 != 0) return null
        return ByteArray(s.length / 2) { i ->
            s.substring(2 * i, 2 * i + 2).toIntOrNull(16)?.toByte() ?: return null
        }
    }

    fun isHex(s: String, count: Int): Boolean =
        s.length == count && s.all { it in '0'..'9' || it in 'a'..'f' || it in 'A'..'F' }
}
