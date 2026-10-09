package com.nostrvault.data.model

import com.nostrvault.util.Bolt11
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.intOrNull

/**
 * How much attention a post got: shown on profile rows, each number on its own
 * action button, so a person can see at a glance which of their posts landed.
 *
 * Kept apart from [NoteStats], which the feed fills from its own subscription
 * and which counts reactions, not people. Port of iOS `PostEngagement`.
 */
data class PostEngagement(
    /** People who reacted. One person reacting twice counts once. */
    val likes: Int = 0,
    /** People who reposted (kind 6, or kind 16 for non-note kinds). */
    val reposts: Int = 0,
    /** Direct replies: kind 1 notes and NIP-22 comments whose parent is this post. */
    val replies: Int = 0,
    /** Notes that quote this post: a NIP-18 `q` tag, or the older `e` tag marked "mention". */
    val quotes: Int = 0,
    /** Total sats across zap receipts. */
    val zapSats: Long = 0,
    /**
     * The counts came from a handful of relays and may be missing what sits on
     * others: true for anyone else's posts. Large numbers then show as "64+" so
     * nobody reads them as exact. Your own posts are counted from your relay's
     * inbox, which receives what's sent to you.
     */
    val isLowerBound: Boolean = false,
) {
    val isEmpty: Boolean
        get() = likes == 0 && reposts == 0 && replies == 0 && quotes == 0 && zapSats == 0L

    /** True when [value] gets a "+": a lower bound, and big enough for the gap to matter. */
    fun isAtLeast(value: Long): Boolean = isLowerBound && value >= LOWER_BOUND_FROM

    companion object {
        /**
         * From this many up, a lower-bound count gets its "+". Small accounts
         * measured within about one of Primal's numbers; the gap opens on
         * popular posts.
         */
        const val LOWER_BOUND_FROM = 10
    }
}

/** One relay event, reduced to what counting needs. */
data class EngagementEvent(
    val id: String,
    val kind: Int,
    val pubkey: String,
    val content: String,
    val tags: List<List<String>>,
) {
    companion object {
        fun from(event: JsonObject): EngagementEvent? {
            val id = (event["id"] as? JsonPrimitive)?.contentOrNull ?: return null
            val kind = (event["kind"] as? JsonPrimitive)?.intOrNull ?: return null
            val pubkey = (event["pubkey"] as? JsonPrimitive)?.contentOrNull ?: return null
            val content = (event["content"] as? JsonPrimitive)?.contentOrNull ?: ""
            val tags = (event["tags"] as? JsonArray)?.mapNotNull { tag ->
                (tag as? JsonArray)?.mapNotNull { (it as? JsonPrimitive)?.contentOrNull }
            } ?: return null
            return EngagementEvent(id, kind, pubkey, content, tags)
        }
    }
}

object PostEngagementQuery {
    const val REACTION_KIND = 7
    val REPOST_KINDS = listOf(6, 16)
    const val ZAP_RECEIPT_KIND = 9735
    val REPLY_KINDS = listOf(1, NIP10Thread.COMMENT_KIND)

    /** A quote is a note (or comment) that names the post in a `q` tag. */
    val QUOTE_KINDS = listOf(1, NIP10Thread.COMMENT_KIND)

    /**
     * Relay filters (JSON) for the engagement on [ids]. The ids are split into
     * small groups because a relay applies `limit` per filter: one filter for
     * fifty posts would stop at the limit and undercount the popular ones.
     * Each group gets a second filter on `#q`: NIP-18 quotes carry the id
     * there, and an `#e` filter never returns them.
     *
     * @param since only engagement newer than this (unix seconds), for posts
     *   already counted once; null asks for everything.
     */
    fun filters(ids: List<String>, since: Long? = null, groupSize: Int = 10, limit: Int = 500): List<String> {
        val kinds = (listOf(REACTION_KIND) + REPOST_KINDS + ZAP_RECEIPT_KIND + REPLY_KINDS).joinToString(",")
        val quoteKinds = QUOTE_KINDS.joinToString(",")
        val sinceField = since?.let { ""","since":$it""" } ?: ""
        return ids.chunked(groupSize.coerceAtLeast(1)).flatMap { group ->
            val list = group.joinToString(",") { "\"$it\"" }
            listOf(
                """{"kinds":[$kinds],"#e":[$list],"limit":$limit$sinceField}""",
                """{"kinds":[$quoteKinds],"#q":[$list],"limit":$limit$sinceField}""",
            )
        }
    }

    /**
     * What points at each of [targets], as the people and events behind the
     * numbers, so a saved ledger can add a later fetch without counting
     * anything twice. Relays answer tag filters loosely and the same event
     * comes from several of them, so each event is checked against its own tags.
     */
    fun contributions(events: List<EngagementEvent>, targets: Set<String>): Map<String, EngagementLedger> {
        val out = HashMap<String, EngagementLedger>()
        fun edit(target: String, change: (EngagementLedger) -> EngagementLedger) {
            out[target] = change(out[target] ?: EngagementLedger())
        }
        fun firstTargetE(tags: List<List<String>>): String? =
            tags.firstOrNull { it.size >= 2 && it[0] == "e" && it[1] in targets }?.get(1)

        for (event in events) {
            val tags = event.tags
            when (event.kind) {
                REACTION_KIND -> {
                    // NIP-25: the reacted-to event is the last `e` tag.
                    val target = tags.lastOrNull { it.size >= 2 && it[0] == "e" }?.get(1) ?: continue
                    if (target !in targets) continue
                    // A "-" is a dislike, not attention worth counting as a like.
                    if (event.content == "-") continue
                    edit(target) { it.copy(likers = it.likers + EngagementLedger.key(event.pubkey)) }
                }
                in REPOST_KINDS -> {
                    val target = firstTargetE(tags) ?: continue
                    edit(target) { it.copy(reposters = it.reposters + EngagementLedger.key(event.pubkey)) }
                }
                ZAP_RECEIPT_KIND -> {
                    val target = firstTargetE(tags) ?: continue
                    val bolt11 = tags.firstOrNull { it.size >= 2 && it[0] == "bolt11" }?.get(1) ?: continue
                    val sats = Bolt11.satsOrNull(bolt11) ?: continue
                    edit(target) { it.copy(zaps = it.zaps + (EngagementLedger.key(event.id) to sats)) }
                }
                else -> {
                    if (event.kind !in REPLY_KINDS && event.kind !in QUOTE_KINDS) continue
                    // A reply counts only on the post it answers; a reply further
                    // down the thread also carries the id in an `e` tag.
                    val parent = NIP10Thread.parentEventId(event.kind, tags)
                    if (event.kind in REPLY_KINDS && parent != null && parent in targets) {
                        edit(parent) { it.copy(replies = it.replies + EngagementLedger.key(event.id)) }
                    }
                    // A quote names the post in a `q` tag (NIP-18) or, from older
                    // clients, an `e` tag marked "mention". One note can quote
                    // several posts; it is not also a quote of the post it replies to.
                    val quoted = tags.mapNotNull { tag ->
                        when {
                            tag.size < 2 -> null
                            tag[0] == "q" -> tag[1]
                            tag[0] == "e" && tag.size >= 4 && tag[3] == "mention" -> tag[1]
                            else -> null
                        }
                    }.toSet().intersect(targets) - setOfNotNull(parent)
                    for (target in quoted) {
                        edit(target) { it.copy(quotes = it.quotes + EngagementLedger.key(event.id)) }
                    }
                }
            }
        }
        return out
    }

    /** Counts for each target, ready to show. Zero-engagement targets are left out. */
    fun tally(events: List<EngagementEvent>, targets: Set<String>): Map<String, PostEngagement> =
        contributions(events, targets).mapNotNull { (id, ledger) ->
            // Whether these are a lower bound depends on where they came from,
            // which only the caller knows.
            val e = ledger.engagement.copy(isLowerBound = false)
            if (e.isEmpty) null else id to e
        }.toMap()
}

/**
 * Everything counted so far for one post: who liked and reposted it, which
 * replies, quotes and zap receipts were seen. Saved between launches so the
 * next visit asks relays only for what's new and adds it, never counting the
 * same like or zap twice.
 *
 * Keys are the first 16 hex characters of a pubkey or event id: 64 bits is
 * plenty to tell a few thousand apart, at a quarter of the storage.
 */
@Serializable
data class EngagementLedger(
    val likers: Set<String> = emptySet(),
    val reposters: Set<String> = emptySet(),
    val replies: Set<String> = emptySet(),
    val quotes: Set<String> = emptySet(),
    /** Zap receipt key → sats. */
    val zaps: Map<String, Long> = emptyMap(),
    /** When relays were last asked about this post, unix seconds. Null until then. */
    val checkedAt: Long? = null,
    /** Counted from relays only (anyone else's post): a lower bound. */
    val isLowerBound: Boolean = true,
) {
    val engagement: PostEngagement
        get() = PostEngagement(
            likes = likers.size,
            reposts = reposters.size,
            replies = replies.size,
            quotes = quotes.size,
            zapSats = zaps.values.sum(),
            isLowerBound = isLowerBound,
        )

    /** Adds what [other] saw. Sets union, so an event seen before adds nothing. */
    fun absorbing(other: EngagementLedger): EngagementLedger = copy(
        likers = likers + other.likers,
        reposters = reposters + other.reposters,
        replies = replies + other.replies,
        quotes = quotes + other.quotes,
        zaps = other.zaps + zaps,
    )

    companion object {
        fun key(hex: String): String = hex.take(16)
    }
}
