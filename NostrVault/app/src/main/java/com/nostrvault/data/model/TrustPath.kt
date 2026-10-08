package com.nostrvault.data.model

import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.intOrNull
import kotlinx.serialization.json.longOrNull

/**
 * A signed follow list (kind 3) as the Trust Path reads it. Built from a
 * relay's event after its signature checks out ([TrustPathService]).
 */
data class ContactList(
    val pubkey: String,
    val createdAt: Long,
    val tags: List<List<String>>,
    val kind: Int = 3,
) {
    companion object {
        fun from(event: JsonObject): ContactList? {
            val pubkey = (event["pubkey"] as? JsonPrimitive)?.contentOrNull ?: return null
            val kind = (event["kind"] as? JsonPrimitive)?.intOrNull ?: return null
            val createdAt = (event["created_at"] as? JsonPrimitive)?.longOrNull ?: 0L
            val tags = (event["tags"] as? JsonArray)?.mapNotNull { tag ->
                (tag as? JsonArray)?.mapNotNull { (it as? JsonPrimitive)?.contentOrNull }
            } ?: return null
            return ContactList(pubkey, createdAt, tags, kind)
        }
    }
}

/**
 * One REQ filter for follow lists: `{"kinds":[3],"authors":…,"#p":…,"limit":…}`.
 * Kept as data so tests can read it; [toJson] is what goes to the relay.
 */
data class FollowListFilter(
    val authors: List<String>?,
    val tagged: List<String>?,
    val limit: Int,
) {
    fun toJson(): String = buildString {
        append("{\"kinds\":[3]")
        authors?.let { append(",\"authors\":").append(quoted(it)) }
        tagged?.let { append(",\"#p\":").append(quoted(it)) }
        append(",\"limit\":").append(limit).append('}')
    }

    private fun quoted(keys: List<String>) = keys.joinToString(",", "[", "]") { "\"$it\"" }
}

/**
 * How a post's author reaches you through your Web of Trust, for the Trust
 * Path card in Event Info. The relay's trust graph (`wot_cache.json`) is only
 * a yes/no set, so the "bridge" people — those you follow who follow the
 * author — are rebuilt from a few signed follow lists (kind 3) on demand.
 *
 * Port of iOS Models/TrustPath.swift.
 */
data class TrustPath(
    val reach: Reach,
    /**
     * Up to [SHOWN_BRIDGES] people you follow who follow the author, sorted by
     * key so a cached answer always draws in the same order.
     */
    val bridges: List<String>,
    /**
     * More bridges were found than are shown. Not a count: an exact count
     * would mean downloading every follow list.
     */
    val hasMore: Boolean,
) {
    enum class Reach {
        /** The author is you. */
        YOU,
        /** You follow the author (1 hop). */
        FOLLOW,
        /** Someone you follow follows the author (2 hops). */
        BRIDGED,
        /** In the relay's trust graph, but no bridge turned up in the lists the relays sent back. */
        WEB,
        /**
         * Not in your trust graph, and no bridge turned up either. Only as
         * sure as the relays asked: a list they lack can't be seen.
         */
        OUTSIDE,
        /** No trust graph loaded yet, so "outside" can't be claimed. */
        UNKNOWN,
    }

    companion object {
        /** Avatars that fit on the card. */
        const val SHOWN_BRIDGES = 5

        /**
         * Follow lists asked for per filter: one more than shown, so "+ more"
         * can be known without fetching everything. Each list is someone's
         * whole follow list (~90 KB at 1,000 follows), so this is the cost knob.
         */
        const val LISTS_PER_FILTER = SHOWN_BRIDGES + 1

        /**
         * Builds the path from follow lists relays returned. Lists signed by
         * anyone you don't follow, or that don't tag the author, are ignored,
         * so a relay can't make up a bridge; only each signer's newest list
         * counts. Signatures are checked by the caller.
         */
        fun resolve(
            author: String,
            me: String,
            follows: Set<String>,
            trustGraph: Set<String>,
            contactLists: List<ContactList>,
        ): TrustPath {
            if (author == me) return TrustPath(Reach.YOU, emptyList(), false)

            val sorted = allBridges(author, me, follows, contactLists)
            val shown = sorted.take(SHOWN_BRIDGES)
            val reach = when {
                author in follows -> Reach.FOLLOW
                shown.isNotEmpty() -> Reach.BRIDGED
                trustGraph.isEmpty() -> Reach.UNKNOWN
                author in trustGraph -> Reach.WEB
                else -> Reach.OUTSIDE
            }
            return TrustPath(reach, shown, sorted.size > SHOWN_BRIDGES)
        }

        /**
         * Every bridge in [contactLists], sorted by key, by the same rules as
         * [resolve]. The globe uses it to light all of them, not just the card's 5.
         */
        fun allBridges(
            author: String,
            me: String,
            follows: Set<String>,
            contactLists: List<ContactList>,
        ): List<String> {
            val newest = HashMap<String, Pair<Long, Boolean>>()
            for (list in contactLists) {
                val signer = list.pubkey
                if (list.kind != 3 || signer == author || signer == me || signer !in follows) continue
                val seen = newest[signer]
                if (seen != null && seen.first >= list.createdAt) continue
                val tagsAuthor = list.tags.any { it.size >= 2 && it[0] == "p" && it[1] == author }
                newest[signer] = list.createdAt to tagsAuthor
            }
            return newest.filterValues { it.second }.keys.sorted()
        }

        /**
         * The follow-list filters to ask for: your follows in chunks, each
         * tagging the author, each capped at [LISTS_PER_FILTER]. relay.primal.net
         * and relay.damus.io both took 1,015 authors in one filter (checked
         * 2026-10-07), so most accounts send a single filter.
         */
        fun filters(author: String, follows: List<String>, chunkSize: Int = 1000): List<FollowListFilter> =
            follows.filter { it != author }.chunked(chunkSize).map {
                FollowListFilter(authors = it, tagged = listOf(author), limit = LISTS_PER_FILTER)
            }
    }
}

/** The one-line summary shared by the card and the globe. */
object TrustPathText {
    fun label(path: TrustPath?, name: (String) -> String): String {
        if (path == null) return "Tracing how they reach you…"
        return when (path.reach) {
            TrustPath.Reach.YOU -> "This is you."
            TrustPath.Reach.FOLLOW ->
                if (path.bridges.isEmpty()) "You follow them · 1 hop"
                else "You follow them · also followed by ${bridgeNames(path, name)}"
            TrustPath.Reach.BRIDGED -> "Followed by ${bridgeNames(path, name)} you follow · 2 hops"
            TrustPath.Reach.WEB -> "In your Web of Trust"
            TrustPath.Reach.OUTSIDE -> "Not in your web · no one you follow follows them"
            TrustPath.Reach.UNKNOWN -> "Your trust graph isn't loaded yet"
        }
    }

    private fun bridgeNames(path: TrustPath, name: (String) -> String): String {
        val names = path.bridges.take(2).map(name)
        val rest = path.bridges.size - names.size
        if (rest > 0 || path.hasMore) return names.joinToString(", ") + " + more"
        return names.joinToString(" and ")
    }
}
