package com.nostrvault.data.model

import kotlinx.serialization.Serializable
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.longOrNull
import kotlinx.serialization.json.put
import java.util.Base64
import java.util.UUID

/**
 * A locally saved draft of a note being composed.
 * Synced to the local relay as kind 31234 (parameterized replaceable event)
 * on the /private endpoint.
 */
@Serializable
data class Draft(
    val id: String = UUID.randomUUID().toString(),
    val content: String,
    val pubkey: String = "",
    val replyToId: String? = null,
    val rootId: String? = null,
    val quoteId: String? = null,
    val quotePubkey: String? = null,
    val tags: List<List<String>> = emptyList(),
    val updatedAt: Long = System.currentTimeMillis(),
) {
    val preview: String
        get() = content.take(80).replace('\n', ' ')

    val isReply: Boolean
        get() = replyToId != null

    val isQuote: Boolean
        get() = quoteId != null
}

@Serializable
data class DraftStore(
    val drafts: List<Draft> = emptyList(),
    /** `31234:<pubkey>:<id>` of drafts deleted here whose relay delete hasn't been confirmed yet. */
    val pendingDeletes: List<String> = emptyList(),
)

/**
 * Drafts as kind 31234 events on the /private relay, in the same tag shape as
 * iOS `DraftService`: `d` is the draft id, NIP-10 `e` tags with `root` /
 * `reply` markers, and `["q", id, hint, pubkey]` for a quote. Reading also
 * accepts the older Android shape (`reply`, `root`, `q`, `qp` tags) so drafts
 * this app published before still come back.
 */
object DraftEvents {
    const val KIND = 31234

    fun tags(draft: Draft): List<List<String>> = buildList {
        add(listOf("d", draft.id))
        add(listOf("k", "1"))
        val reply = draft.replyToId
        if (reply != null) {
            add(listOf("e", draft.rootId ?: reply, "", "root"))
            add(listOf("e", reply, "", "reply"))
        }
        draft.quoteId?.let { add(listOf("q", it, "", draft.quotePubkey ?: "")) }
    }

    /** A draft from a relay event, or null when it has no `d` tag. [createdAt] is in seconds. */
    fun fromEvent(content: String, pubkey: String, tags: List<List<String>>, createdAt: Long): Draft? {
        val id = tags.firstOrNull { it.size >= 2 && it[0] == "d" }?.get(1)?.takeIf { it.isNotEmpty() } ?: return null
        fun marked(marker: String) = tags.firstOrNull { it.size >= 4 && it[0] == "e" && it[3] == marker }?.get(1)
        fun legacy(name: String) = tags.firstOrNull { it.size >= 2 && it[0] == name }?.get(1)
        val q = tags.firstOrNull { it.size >= 2 && it[0] == "q" }
        return Draft(
            id = id,
            content = content,
            pubkey = pubkey,
            replyToId = marked("reply") ?: legacy("reply"),
            rootId = marked("root") ?: legacy("root"),
            quoteId = q?.get(1),
            quotePubkey = q?.getOrNull(3)?.takeIf { it.isNotEmpty() } ?: legacy("qp"),
            tags = tags,
            updatedAt = createdAt * 1000,
        )
    }

    /**
     * Local drafts plus the relay's, newest first. For one id the newer copy
     * wins and a tie goes to the relay, as on iOS. Local-only drafts stay.
     */
    fun merge(local: List<Draft>, relay: List<Draft>, deleted: Set<String> = emptySet()): List<Draft> {
        val merged = LinkedHashMap<String, Draft>()
        for (d in local) merged[d.id] = d
        for (d in relay) {
            // Deleted here, but the relay still has it: the delete is pending or in flight.
            if (d.id in deleted) continue
            val existing = merged[d.id]
            if (existing == null || d.updatedAt >= existing.updatedAt) merged[d.id] = d
        }
        return merged.values.sortedByDescending { it.updatedAt }
    }

    /** The NIP-09 `a` coordinate a kind 5 deletes [id] by. */
    fun coordinate(pubkey: String, id: String): String = "$KIND:$pubkey:$id"

    fun idOf(coordinate: String): String = coordinate.split(":", limit = 3).getOrElse(2) { "" }

    // ── NIP-37: the draft encrypted to the author's own key ──────────────
    // The note being drafted (kind, text, tags, time) as JSON, NIP-44
    // encrypted to self, with only `d` and `k` outside. Drafts used to go in
    // plain text; those still open, marked so they are saved again encrypted.
    // iOS: DraftEnvelope.swift.

    private val outside = setOf("d", "k")

    class Sealed(val content: String, val tags: List<List<String>>)

    /** A fetched draft, opened. [createdAt] (seconds) is from inside; null for an old plaintext draft. */
    data class Opened(val content: String, val tags: List<List<String>>, val createdAt: Long?, val wasPlaintext: Boolean)

    /** A kind 31234 as the relay returned it. [createdAt] is in seconds. */
    data class Fetched(val content: String, val pubkey: String, val tags: List<List<String>>, val createdAt: Long)

    /**
     * The content and tags to sign for a draft whose full tags are [tags]
     * (d, k, e, q): everything but d and k goes inside. Null when [encrypt]
     * gives nothing: a draft is never sent unencrypted.
     */
    suspend fun seal(content: String, tags: List<List<String>>, updatedAtMs: Long, encrypt: suspend (String) -> String?): Sealed? {
        val outer = tags.filter { it.size >= 2 && it[0] in outside }
        val inner = tags.filter { it.firstOrNull() !in outside }
        val kind = outer.firstOrNull { it[0] == "k" }?.get(1)?.toIntOrNull() ?: 1
        val event = buildJsonObject {
            put("kind", kind)
            put("content", content)
            put("tags", JsonArray(inner.map { t -> JsonArray(t.map(::JsonPrimitive)) }))
            put("created_at", updatedAtMs / 1000)
        }
        val ciphertext = encrypt(event.toString())?.takeIf { it.isNotEmpty() } ?: return null
        return Sealed(ciphertext, outer)
    }

    /**
     * A fetched draft's text and tags (the old shape: outer d/k, then the
     * inner tags). Text that isn't a NIP-44 payload is an old draft and opens
     * as it is. Null when it is encrypted and can't be opened: its ciphertext
     * is never shown as the draft's text.
     */
    suspend fun open(content: String, tags: List<List<String>>, decrypt: suspend (String) -> String?): Opened? {
        if (!looksEncrypted(content)) return Opened(content, tags, null, wasPlaintext = true)
        val plain = decrypt(content) ?: return null
        val obj = runCatching { Json.parseToJsonElement(plain) as? JsonObject }.getOrNull() ?: return null
        val text = (obj["content"] as? JsonPrimitive)?.takeIf { it.isString }?.content ?: return null
        val inner = (obj["tags"] as? JsonArray)?.mapNotNull { t ->
            val arr = t as? JsonArray ?: return@mapNotNull null
            val strings = arr.mapNotNull { (it as? JsonPrimitive)?.takeIf { p -> p.isString }?.content }
            strings.takeIf { it.size == arr.size && it.isNotEmpty() && it[0] !in outside }
        } ?: emptyList()
        val outer = tags.filter { it.size >= 2 && it[0] in outside }
        val created = (obj["created_at"] as? JsonPrimitive)?.longOrNull
        return Opened(text, outer + inner, created, wasPlaintext = false)
    }

    /**
     * Opens what a fetch returned: the drafts that open, with the time they
     * were saved, and the ids of old plaintext ones to save again encrypted.
     */
    suspend fun openAll(events: List<Fetched>, decrypt: suspend (String) -> String?): Pair<List<Draft>, Set<String>> {
        val drafts = mutableListOf<Draft>()
        val plaintext = mutableSetOf<String>()
        for (e in events) {
            val opened = open(e.content, e.tags, decrypt) ?: continue
            val draft = fromEvent(opened.content, e.pubkey, opened.tags, opened.createdAt ?: e.createdAt) ?: continue
            drafts.add(draft)
            if (opened.wasPlaintext) plaintext.add(draft.id)
        }
        return drafts to plaintext
    }

    /**
     * A NIP-44 v2 payload: base64 of at least 99 bytes (version, nonce,
     * padded ciphertext, MAC) whose first byte is 2. Typed text almost never is.
     */
    fun looksEncrypted(content: String): Boolean {
        if (content.length < 132 || content.length > 87_472) return false
        val bytes = runCatching { Base64.getDecoder().decode(content) }.getOrNull() ?: return false
        return bytes.size >= 99 && bytes[0].toInt() == 2
    }

    /** Drafts the active account may see: its own, plus old ones saved before drafts had an owner. */
    fun forAccount(drafts: List<Draft>, account: String): List<Draft> =
        drafts.filter { it.pubkey.isEmpty() || it.pubkey == account }
}
