package com.nostrvault.data.model

import kotlinx.serialization.Serializable
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

    /** Drafts the active account may see: its own, plus old ones saved before drafts had an owner. */
    fun forAccount(drafts: List<Draft>, account: String): List<Draft> =
        drafts.filter { it.pubkey.isEmpty() || it.pubkey == account }
}
