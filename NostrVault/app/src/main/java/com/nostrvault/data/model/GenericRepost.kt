package com.nostrvault.data.model

import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.intOrNull

/**
 * The rules for reading a repost (kind 6, or NIP-18's generic kind 16).
 * Pure, so the feed and the tests share one copy. iOS: `GenericRepost`.
 */
object GenericRepost {
    /** NIP-18 generic repost: a repost of anything but a text note. */
    const val KIND = 16

    /**
     * The kinds a repost may carry into a timeline: the ones drawn as a card
     * there (a note, comment, article, poll, picture or highlight). A repost
     * of anything else (a video, live stream, calendar event) would show as a
     * bare text body, so it is left out.
     */
    val SHOWN_KINDS: Set<Int> = setOf(
        1, NIP10Thread.COMMENT_KIND, ArticleMeta.KIND, NIP88Poll.KIND,
        FeedNote.PICTURE_KIND, FeedHighlight.KIND,
    )

    /**
     * The kind of the event a repost carries in its content, or null when the
     * content is empty or not an event. An embedded event with no `kind` is
     * read as a text note, as kind 6 always assumed.
     */
    fun embeddedKind(content: String): Int? {
        if (content.isEmpty()) return null
        val inner = try {
            Json.parseToJsonElement(content) as? JsonObject
        } catch (_: Exception) {
            null
        } ?: return null
        if ((inner["pubkey"] as? JsonPrimitive)?.isString != true) return null
        return (inner["kind"] as? JsonPrimitive)?.intOrNull ?: 1
    }

    /**
     * Whether a timeline shows this repost: by its `k` tag (NIP-18), else by
     * the event it embeds, else (bare, untagged) yes, as kind 6 always has.
     */
    fun isShown(tags: List<List<String>>, content: String): Boolean {
        tags.firstOrNull { it.size >= 2 && it[0] == "k" }?.get(1)?.toIntOrNull()?.let {
            return it in SHOWN_KINDS
        }
        embeddedKind(content)?.let { return it in SHOWN_KINDS }
        return true
    }
}
