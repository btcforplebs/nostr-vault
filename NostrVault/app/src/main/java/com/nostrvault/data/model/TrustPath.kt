package com.nostrvault.data.model

import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.intOrNull
import kotlinx.serialization.json.longOrNull
import kotlin.math.PI
import kotlin.math.cos
import kotlin.math.sin

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
         * [resolve]. The map uses it to light all of them, not just the card's 5.
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

/**
 * The pure parts of the Web of Trust map: where each person sits, which
 * follow lists to ask for next, and the 3-hop "look deeper" chains. No layout
 * is ever iterated: a person's spot comes straight from their key, so the same
 * person sits in the same place every time the map opens.
 *
 * Port of iOS Models/TrustMap.swift.
 */
object TrustMap {
    /** Follow lists asked for per "show everyone" batch (~2 MB a batch). */
    const val BATCH_SIZE = 20
    /** Stop "show everyone" here (~9 MB). Past it the button asks again. */
    const val MAX_BATCHED_LISTS = 100
    /** Lists tagging the author fetched from anyone for "look deeper". */
    const val DEEPER_SEEDS = 30
    /** Lists from your follows that tag one of those seeds. */
    const val DEEPER_LINKS = 12
    /** Faces drawn for 3-hop chains; the rest stay dots. */
    const val SHOWN_CHAINS = 12

    /** How far a dot may sit in or out of the ring, in ring radii. */
    const val BAND_WIDTH = 0.08

    /**
     * Where someone sits on a ring, in degrees from 0 up to 360, from the first
     * 8 hex digits of their key. The key is already uniformly random, so its
     * leading bits spread people evenly.
     */
    fun angle(pubkey: String): Double = fraction(pubkey, 0) * 360

    /** −1…1 from the next 8 hex digits: a small in-or-out nudge so dots form a band. */
    fun band(pubkey: String): Double = fraction(pubkey, 8) * 2 - 1

    private fun fraction(pubkey: String, offset: Int): Double {
        val hex = pubkey.drop(offset).take(8)
        if (hex.length == 8 && hex.all { it in '0'..'9' || it in 'a'..'f' || it in 'A'..'F' }) {
            return hex.toLong(16) / 4_294_967_296.0
        }
        // Not hex (only in tests or a malformed tag): FNV-1a, still stable.
        var hash = 2_166_136_261u
        for (byte in pubkey.encodeToByteArray().drop(offset)) {
            hash = (hash xor byte.toUByte().toUInt()) * 16_777_619u
        }
        return hash.toDouble() / 4_294_967_296.0
    }

    /** A point at [degrees] (0 = up, clockwise) and radius [r], in ring units. */
    fun polar(degrees: Double, r: Double): Pair<Double, Double> {
        val rad = (degrees - 90) * PI / 180
        return r * cos(rad) to r * sin(rad)
    }

    /** A ring member's spot, from their key alone. */
    fun dot(pubkey: String): Pair<Double, Double> = polar(angle(pubkey), 1 + BAND_WIDTH * band(pubkey))

    /**
     * Up to [count] of [sorted], evenly spaced through it. Keys sort in ring
     * order, so taking the first few would bunch every face on one arc.
     */
    fun spread(sorted: List<String>, count: Int): List<String> {
        if (sorted.size <= count || count <= 0) return sorted
        return (0 until count).map { sorted[it * sorted.size / count] }
    }

    /**
     * The next "show everyone" filters: follows whose lists haven't come back
     * yet, tagging the author, chunked for relays that cap a request's size.
     * Empty once every follow has been asked about.
     */
    fun nextBatch(
        author: String,
        follows: List<String>,
        seen: Set<String>,
        chunkSize: Int = 1000,
    ): List<FollowListFilter> =
        follows.filter { it != author && it !in seen }.chunked(chunkSize).map {
            FollowListFilter(authors = it, tagged = listOf(author), limit = BATCH_SIZE)
        }

    /**
     * The p-tags of the newest follow list [owner] signed: who they follow.
     * Lists from anyone else are ignored. Null when no list came back.
     */
    fun follows(owner: String, lists: List<ContactList>): List<String>? {
        val best = lists.filter { it.kind == 3 && it.pubkey == owner }
            .fold(null as ContactList?) { newest, list -> if (newest != null && newest.createdAt >= list.createdAt) newest else list }
            ?: return null
        val seen = HashSet<String>()
        return best.tags.mapNotNull { tag ->
            if (tag.size >= 2 && tag[0] == "p" && tag[1].length == 64 && tag[1] != owner && seen.add(tag[1])) tag[1] else null
        }
    }

    /** One 3-hop route: you follow [bridge], who follows [via], who follows the author. */
    data class Chain(val bridge: String, val via: String)

    /** Step 1 of "look deeper": anyone's follow list that tags the author. */
    fun deeperSeedFilter(author: String) = FollowListFilter(authors = null, tagged = listOf(author), limit = DEEPER_SEEDS)

    /**
     * Who the seed lists say follows the author, minus you, your follows and
     * the author: the possible middle steps. People already in your trust
     * graph come first, since your follows most likely follow them.
     */
    fun deeperVia(
        author: String,
        me: String,
        follows: Set<String>,
        trustGraph: Set<String>,
        seeds: List<ContactList>,
    ): List<String> {
        val candidates = TrustPath.allBridges(author, me, seeds.mapTo(HashSet()) { it.pubkey }, seeds)
            .filter { it !in follows }
        if (trustGraph.isEmpty()) return candidates
        return candidates.filter { it in trustGraph } + candidates.filter { it !in trustGraph }
    }

    /** Step 2: lists from your follows that tag any of the middle steps. */
    fun deeperLinkFilters(follows: List<String>, via: List<String>, chunkSize: Int = 1000): List<FollowListFilter> {
        if (via.isEmpty()) return emptyList()
        return follows.chunked(chunkSize).map { FollowListFilter(authors = it, tagged = via, limit = DEEPER_LINKS) }
    }

    /**
     * Every route the link lists show, sorted by middle step then bridge. Only
     * each follow's newest list counts, as in [TrustPath.resolve].
     */
    fun chains(me: String, follows: Set<String>, via: List<String>, links: List<ContactList>): List<Chain> {
        val viaSet = via.toSet()
        val routes = HashSet<Chain>()
        val bridges = links.map { it.pubkey }.distinct().filter { it in follows && it != me }.sorted()
        for (bridge in bridges) {
            for (target in follows(bridge, links).orEmpty()) {
                if (target in viaSet) routes += Chain(bridge, target)
            }
        }
        return routes.sortedWith(compareBy({ it.via }, { it.bridge }))
    }
}

/** The one-line summary shared by the card and the map. */
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
