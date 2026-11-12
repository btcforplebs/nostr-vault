package com.nostrvault.data.model

import kotlinx.serialization.Serializable
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.longOrNull
import kotlinx.serialization.json.put
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

    /**
     * The tags a draft is saved to the relay with: the ones it came with when
     * it has any beyond d/k (an iPhone or Mac draft keeps its p tags and relay
     * hints; rebuilding from the fields would drop them), else [tags]. A
     * draft edited here is a new [Draft] with no tags, so it gets [tags].
     */
    fun tagsToSave(draft: Draft): List<List<String>> {
        val carried = draft.tags.filter { it.isNotEmpty() && it[0] !in outside }
        if (carried.none { it.size >= 2 }) return tags(draft)
        val kind = draft.tags.firstOrNull { it.size >= 2 && it[0] == "k" }?.get(1) ?: "1"
        return listOf(listOf("d", draft.id), listOf("k", kind)) + carried
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
    data class Fetched(val id: String, val content: String, val pubkey: String, val tags: List<List<String>>, val createdAt: Long)

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
        val payload = encryptedPayload(content) ?: return Opened(content, tags, null, wasPlaintext = true)
        val plain = decrypt(payload) ?: return null
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
    suspend fun openAll(
        events: List<Fetched>,
        cache: MutableMap<String, Opened> = mutableMapOf(),
        decrypt: suspend (String) -> String?,
    ): Pair<List<Draft>, Set<String>> {
        val drafts = mutableListOf<Draft>()
        val plaintext = mutableSetOf<String>()
        val opens = mutableMapOf<String, Opened>()
        for (e in events) {
            // The event id covers the content: one opened before needs no
            // second decrypt (a bunker round trip). Only ones that opened are
            // kept, so a signer that wasn't ready is asked again next time.
            val opened = cache[e.id] ?: open(e.content, e.tags, decrypt) ?: continue
            if (e.id.isNotEmpty()) opens[e.id] = opened
            val draft = fromEvent(opened.content, e.pubkey, opened.tags, opened.createdAt ?: e.createdAt) ?: continue
            drafts.add(draft)
            if (opened.wasPlaintext) plaintext.add(draft.id)
        }
        // Only the events the relay still has, so the cache doesn't grow.
        cache.clear()
        cache.putAll(opens)
        return drafts to plaintext
    }

    fun looksEncrypted(content: String): Boolean = encryptedPayload(content) != null

    /**
     * The content as a NIP-44 payload to decrypt, or null for plain text.
     * The same rule as iOS DraftEnvelope.encryptedPayload, on purpose
     * lenient: a miss shows ciphertext as text and saves it again, so
     * anything shaped like one counts. Trimmed of ASCII spaces and line
     * ends, then 132 to 87,472 characters of standard base64 (99 to 65,603 bytes: version, nonce,
     * padded ciphertext, MAC) with or without its `=` padding. Text people
     * type has spaces or punctuation long before 132 characters.
     */
    fun encryptedPayload(content: String): String? {
        val trimmed = content.trim(' ', '\t', '\n', '\r')
        val body = trimmed.removeSuffix("==").let { if (it.length == trimmed.length) trimmed.removeSuffix("=") else it }
        if (trimmed.length < 132 || trimmed.length > 87_472 || body.length % 4 == 1) return null
        // Padding, when there is any, fills out the last group of four.
        if (body.length != trimmed.length && trimmed.length % 4 != 0) return null
        if (!body.all { it in 'A'..'Z' || it in 'a'..'z' || it in '0'..'9' || it == '+' || it == '/' }) return null
        return trimmed
    }

    /** Drafts the active account may see: its own, plus old ones saved before drafts had an owner. */
    fun forAccount(drafts: List<Draft>, account: String): List<Draft> =
        drafts.filter { it.pubkey.isEmpty() || it.pubkey == account }
}
