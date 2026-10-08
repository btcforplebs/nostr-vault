package com.nostrvault.data.model

import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.put

/**
 * Tags for reacting to and highlighting a long-form article.
 *
 * Mirrors HavenApp/HavenApp/Models/ArticleEngagement.swift. An article is
 * addressable, so a like or a highlight names it by its `a` coordinate as
 * well as this version's `e` id; otherwise clients that count by address
 * never see it, and an edit orphans it.
 */
object ArticleEngagement {
    const val HIGHLIGHT_KIND = 9802
    const val MAX_PASSAGE_LENGTH = 1_000
    const val MAX_SHOWN_HIGHLIGHTS = 50

    /** NIP-25 reaction tags. `a` only appears when the event is addressable. */
    fun reactionTags(id: String, kind: Int, pubkey: String, tags: List<List<String>>, relayHint: String): List<List<String>> =
        buildList {
            add(listOf("e", id, relayHint, pubkey))
            NIP10Thread.coordinate(kind, pubkey, tags)?.let { add(listOf("a", it, relayHint)) }
            add(listOf("p", pubkey))
            add(listOf("k", kind.toString()))
        }

    /**
     * NIP-84 highlight tags. `context` is the surrounding paragraph and is only
     * sent when the highlight is a trimmed part of it; `comment` turns it into
     * a quote highlight.
     */
    fun highlightTags(
        id: String,
        kind: Int,
        pubkey: String,
        tags: List<List<String>>,
        relayHint: String,
        passage: String,
        context: String,
        comment: String,
    ): List<List<String>> = buildList {
        NIP10Thread.coordinate(kind, pubkey, tags)?.let { add(listOf("a", it, relayHint)) }
        add(listOf("e", id, relayHint))
        add(listOf("p", pubkey, relayHint, "author"))
        val p = passage.trim()
        val c = context.trim()
        if (c.isNotEmpty() && c != p) add(listOf("context", c))
        comment.trim().takeIf { it.isNotEmpty() }?.let { add(listOf("comment", it)) }
        add(listOf("alt", "Highlight: \"$p\""))
    }

    /**
     * The article split into blocks a reader can tap to highlight: runs of
     * text separated by blank lines, with fenced code kept whole.
     */
    fun blocks(markdown: String): List<String> {
        val out = mutableListOf<String>()
        val current = StringBuilder()
        var inFence = false
        fun flush() {
            val b = current.toString().trim()
            if (b.isNotEmpty()) out.add(b)
            current.clear()
        }
        for (line in markdown.lines()) {
            if (line.trimStart().startsWith("```")) inFence = !inFence
            if (!inFence && line.isBlank()) {
                flush()
            } else {
                if (current.isNotEmpty()) current.append('\n')
                current.append(line)
            }
        }
        flush()
        return out
    }

    private val linkPattern = Regex("""!?\[([^\]]*)]\([^)]*\)""")
    private val emphasisPattern = Regex("""(\*\*|__|\*|_|~~|`)""")
    private val linePrefixPattern = Regex("""^\s{0,3}(#{1,6}\s+|>\s?|[-*+]\s+|\d+[.)]\s+)""")

    /** The highlightable text of a markdown block, with markup stripped. */
    fun plainText(markdown: String): String =
        markdown.lines().joinToString("\n") { line ->
            linePrefixPattern.replace(line, "")
                .let { linkPattern.replace(it) { m -> m.groupValues[1] } }
                .let { emphasisPattern.replace(it, "") }
        }.trim()

    /**
     * REQ filters for highlights of an article: by its `a` coordinate (every
     * version) and by this version's id.
     */
    fun highlightFilters(id: String, coordinate: String?, limit: Int = 200): List<String> = buildList {
        if (coordinate != null) {
            add(buildJsonObject {
                put("kinds", JsonArray(listOf(JsonPrimitive(HIGHLIGHT_KIND))))
                put("#a", JsonArray(listOf(JsonPrimitive(coordinate))))
                put("limit", limit)
            }.toString())
        }
        add(buildJsonObject {
            put("kinds", JsonArray(listOf(JsonPrimitive(HIGHLIGHT_KIND))))
            put("#e", JsonArray(listOf(JsonPrimitive(id))))
            put("limit", limit)
        }.toString())
    }

    /** The highlights to show: newest first, deduplicated, at most [MAX_SHOWN_HIGHLIGHTS]. */
    fun shown(highlights: List<ArticleHighlight>): List<ArticleHighlight> =
        highlights.sortedByDescending { it.createdAt }
            .distinctBy { it.id }
            .take(MAX_SHOWN_HIGHLIGHTS)

    /**
     * Each block's highlights, keyed by block index: a highlight goes on the
     * first block whose plain text contains its passage, ignoring case and
     * runs of whitespace. Passages not in the text as shown are left out.
     */
    fun place(highlights: List<ArticleHighlight>, blocks: List<String>): Map<Int, List<ArticleHighlight>> {
        val normalizedBlocks = blocks.map { normalized(plainText(it)) }
        val out = mutableMapOf<Int, MutableList<ArticleHighlight>>()
        for (highlight in highlights) {
            val needle = normalized(highlight.passage)
            if (needle.isEmpty()) continue
            val index = normalizedBlocks.indexOfFirst { it.contains(needle) }
            if (index >= 0) out.getOrPut(index) { mutableListOf() }.add(highlight)
        }
        return out
    }

    fun normalized(text: String): String =
        text.lowercase().split(Regex("\\s+")).filter { it.isNotEmpty() }.joinToString(" ")
}

/** Someone's highlight (NIP-84, kind 9802) of an article. */
data class ArticleHighlight(
    val id: String,
    val pubkey: String,
    val passage: String,
    val comment: String?,
    /** Unix seconds. */
    val createdAt: Long,
    /** The 9802's own tags, kept so a reply can thread onto it. */
    val tags: List<List<String>>,
) {
    /** The highlight as a note, for composing a comment on it. */
    fun toNote(): FeedNote =
        FeedNote.fromEvent(id, pubkey, passage, tags, createdAt, ArticleEngagement.HIGHLIGHT_KIND)

    companion object {
        /**
         * How far ahead of the clock a highlight may be dated. The newest are
         * the ones shown, so one dated in 2099 would push every real one off
         * the list; this allows only for clock drift.
         */
        const val MAX_FUTURE_SKEW_SECONDS = 600L

        /**
         * Accepts only a 9802 that points at this article, by its coordinate
         * or this version's id, and has a passage. The caller checks the
         * signature; this checks the shape.
         */
        fun from(
            kind: Int,
            id: String,
            pubkey: String,
            content: String,
            createdAt: Long,
            tags: List<List<String>>,
            articleId: String,
            coordinate: String?,
            nowSeconds: Long = System.currentTimeMillis() / 1000,
        ): ArticleHighlight? {
            if (kind != ArticleEngagement.HIGHLIGHT_KIND) return null
            if (createdAt > nowSeconds + MAX_FUTURE_SKEW_SECONDS) return null
            val pointsHere = tags.any { tag ->
                tag.size >= 2 && when (tag[0]) {
                    "e" -> tag[1] == articleId
                    "a" -> coordinate != null && tag[1] == coordinate
                    else -> false
                }
            }
            val passage = content.trim()
            if (!pointsHere || passage.isEmpty() || passage.length > ArticleEngagement.MAX_PASSAGE_LENGTH) return null
            val comment = tags.firstOrNull { it.size >= 2 && it[0] == "comment" }?.get(1)?.trim()
            return ArticleHighlight(id, pubkey, passage, comment?.takeIf { it.isNotEmpty() }, createdAt, tags)
        }
    }
}

// ── Likes, zaps and comments ─────────────────────────────────────────

/** The fields of a raw relay event that [ArticleEngagement.tally] reads. */
data class ArticleEngagementEvent(
    val id: String,
    val kind: Int,
    val pubkey: String,
    val content: String,
    /** Unix seconds. */
    val createdAt: Long,
    val tags: List<List<String>>,
) {
    fun toNote(): FeedNote = FeedNote.fromEvent(id, pubkey, content, tags, createdAt, kind)
}

/**
 * What the network says about an article: likes, zaps and comments.
 *
 * Mirrors `ArticleTally` in HavenApp/HavenApp/Models/ArticleEngagement.swift.
 */
data class ArticleTally(
    /** People who reacted, not reactions: one person liking twice is one like. */
    val likers: Set<String> = emptySet(),
    val zaps: Int = 0,
    val zapSats: Long = 0,
    /** Every comment, including replies to comments. */
    val commentCount: Int = 0,
    /** Comments on the article itself, oldest first. Replies open from their comment. */
    val topLevelComments: List<ArticleEngagementEvent> = emptyList(),
    /** Replies to each comment, keyed by the comment's id. */
    val replyCounts: Map<String, Int> = emptyMap(),
) {
    /** How much this tally has found, to keep a later snapshot from being replaced by a smaller one. */
    val size: Int get() = likers.size + zaps + commentCount
}

object ArticleTallies {
    const val REACTION_KIND = 7
    const val ZAP_RECEIPT_KIND = 9735
    /** NIP-22 comment, what NIP-23 asks for on an article. */
    const val COMMENT_KIND = 1111
    /** Older clients reply to an article with a plain kind 1 note. */
    const val NOTE_KIND = 1

    private val json = kotlinx.serialization.json.Json { ignoreUnknownKeys = true }

    /**
     * REQ filters for an article's likes, zaps and comments. By `a`
     * coordinate (survives edits) and by this version's `e` id; NIP-22
     * comments also carry the article as their uppercase root, which is the
     * only tag a reply to a comment has that points at the article.
     */
    fun engagementFilters(id: String, coordinate: String?, limit: Int = 500): List<String> {
        val kinds = JsonArray(listOf(REACTION_KIND, ZAP_RECEIPT_KIND, COMMENT_KIND, NOTE_KIND).map { JsonPrimitive(it) })
        val commentOnly = JsonArray(listOf(JsonPrimitive(COMMENT_KIND)))
        fun filter(kinds: JsonArray, tag: String, value: String) = buildJsonObject {
            put("kinds", kinds)
            put(tag, JsonArray(listOf(JsonPrimitive(value))))
            put("limit", limit)
        }.toString()
        return buildList {
            add(filter(kinds, "#e", id))
            add(filter(commentOnly, "#E", id))
            if (coordinate != null) {
                add(filter(kinds, "#a", coordinate))
                add(filter(commentOnly, "#A", coordinate))
            }
        }
    }

    /**
     * Sats a zap receipt paid: the request's `amount` tag, then the
     * receipt's own, then the invoice. Same rungs as the live chat.
     */
    fun zapSats(receiptTags: List<List<String>>): Long = com.nostrvault.util.ZapAmount.sats(receiptTags)

    /**
     * Counts what points at this article. The caller checks signatures and
     * drops spam; this checks that each event really is about this article,
     * since a relay may answer a tag filter loosely.
     */
    fun tally(
        events: List<ArticleEngagementEvent>,
        articleId: String,
        coordinate: String?,
        nowSeconds: Long = System.currentTimeMillis() / 1000,
    ): ArticleTally {
        fun pointsHere(tags: List<List<String>>, lower: Boolean = true, upper: Boolean = false): Boolean =
            tags.any { tag ->
                if (tag.size < 2) return@any false
                val isE = (lower && tag[0] == "e") || (upper && tag[0] == "E")
                val isA = (lower && tag[0] == "a") || (upper && tag[0] == "A")
                (isE && tag[1] == articleId) || (isA && coordinate != null && tag[1] == coordinate)
            }

        val likers = mutableSetOf<String>()
        var zaps = 0
        var zapSats = 0L
        val seen = mutableSetOf<String>()
        // (event, parent id or null when it is on the article itself)
        val comments = mutableListOf<Pair<ArticleEngagementEvent, String?>>()

        for (event in events) {
            if (!seen.add(event.id)) continue
            if (event.createdAt > nowSeconds + ArticleHighlight.MAX_FUTURE_SKEW_SECONDS) continue
            val tags = event.tags
            when (event.kind) {
                REACTION_KIND -> {
                    // "-" is a dislike (NIP-25).
                    if (pointsHere(tags) && event.content != "-") likers.add(event.pubkey)
                }
                ZAP_RECEIPT_KIND -> {
                    if (!pointsHere(tags)) continue
                    zaps += 1
                    zapSats += zapSats(tags)
                }
                COMMENT_KIND -> {
                    if (!pointsHere(tags, lower = true, upper = true)) continue
                    // Lowercase tags name the parent: the article makes it
                    // top-level, otherwise it replies to the comment its `e` names.
                    val parent = if (pointsHere(tags)) null
                    else tags.firstOrNull { it.size >= 2 && it[0] == "e" }?.get(1)
                    comments.add(event to parent)
                }
                NOTE_KIND -> {
                    // A mention or quote names the article without replying to it.
                    val replyTags = tags.filter {
                        it.size >= 2 && (it[0] == "e" || it[0] == "a") && (it.size < 4 || it[3] != "mention")
                    }
                    if (!pointsHere(replyTags)) continue
                    // NIP-10: the reply-marked `e` is the parent; with no
                    // markers the last `e` is. Top-level when it is the article.
                    val eTags = replyTags.filter { it[0] == "e" }
                    val parent = (eTags.firstOrNull { it.size >= 4 && it[3] == "reply" } ?: eTags.lastOrNull())?.get(1)
                    comments.add(event to parent?.takeIf { it != articleId })
                }
            }
        }

        val replyCounts = mutableMapOf<String, Int>()
        for ((_, parent) in comments) if (parent != null) replyCounts[parent] = (replyCounts[parent] ?: 0) + 1
        return ArticleTally(
            likers = likers,
            zaps = zaps,
            zapSats = zapSats,
            commentCount = comments.size,
            topLevelComments = comments.filter { it.second == null }.map { it.first }.sortedBy { it.createdAt },
            replyCounts = replyCounts,
        )
    }
}
