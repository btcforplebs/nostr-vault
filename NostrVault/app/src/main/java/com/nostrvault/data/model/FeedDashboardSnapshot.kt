package com.nostrvault.data.model

import com.nostrvault.data.music.WavlakeLink
import com.nostrvault.util.Bolt11

/** One event as the dashboard reads it. */
data class DashboardEvent(
    val id: String,
    val pubkey: String,
    val kind: Int,
    val createdAt: Long,
    val content: String,
    val tags: List<List<String>>,
)

/**
 * The feed dashboard: what your follows did in the last 24 hours, every card
 * derived from one load. Pure, so it is unit-testable. Port of iOS
 * FeedDashboardSnapshot (FeedDashboardStore.swift).
 */
data class FeedDashboardSnapshot(
    val posts: Int = 0,
    val activePeople: Int = 0,
    val satsReceived: Long = 0,
    val newFollowers: Int = 0,
    val live: List<LiveStream> = emptyList(),
    /** Authors by post count, most first. */
    val mostActive: List<Ranked> = emptyList(),
    val popular: List<PopularNote> = emptyList(),
    /** Hashtags by how many follows used them. */
    val trending: List<Ranked> = emptyList(),
    val tiles: List<Tile> = emptyList(),
) {
    data class Ranked(val id: String, val count: Int)

    data class PopularNote(
        val id: String,
        /** Distinct follows who liked, reposted or quoted it. */
        val people: Int,
        val note: FeedNote? = null,
    )

    data class Tile(
        val mode: FeedMode?,
        val label: String,
        val count: Int,
        /** One line from the newest item. */
        val preview: String?,
    )

    /** Everyone the cards draw an avatar or a name for. */
    val profilePubkeys: List<String>
        get() = (mostActive.take(12).map { it.id } + live.map { it.hostPubkey } +
            popular.mapNotNull { it.note?.pubkey }).distinct()

    fun withPopularNotes(events: List<DashboardEvent>): FeedDashboardSnapshot {
        val notes = events.associateBy { it.id }
        return copy(
            popular = popular.map { p -> if (p.note != null) p else p.copy(note = notes[p.id]?.let(::note)) }
                .filter { it.note != null },
        )
    }

    companion object {
        const val WINDOW_SECONDS = 24L * 60 * 60
        const val POLL_KIND = 1068
        const val ARTICLE_KIND = 30023
        const val DIVINE_KIND = 34236
        const val ZAP_RECEIPT_KIND = 9735

        fun build(
            events: List<DashboardEvent>,
            zapReceipts: List<DashboardEvent>,
            followers: FollowerSnapshot?,
            follows: Set<String>,
            owner: String,
            blocked: Set<String>,
            since: Long,
            now: Long,
        ): FeedDashboardSnapshot {
            val seen = HashSet<String>()
            var posts = 0
            val postsBy = HashMap<String, Int>()
            val tagPeople = HashMap<String, MutableSet<String>>()
            val likedBy = HashMap<String, MutableSet<String>>()
            val notesById = HashMap<String, FeedNote>()
            val polls = ArrayList<DashboardEvent>()
            val articles = ArrayList<DashboardEvent>()
            val recipes = ArrayList<DashboardEvent>()
            val diVines = ArrayList<DashboardEvent>()
            val music = ArrayList<DashboardEvent>()
            val listings = ArrayList<Pair<DashboardEvent, MarketListing>>()
            val liveByAddress = HashMap<String, LiveStream>()

            for (e in events) {
                if (!seen.add(e.id) || e.pubkey in blocked) continue

                if (e.kind == LiveStream.KIND) {
                    // Hosted on a service, a stream's author is the service;
                    // the host is in a `p` tag. Either one being followed counts.
                    val stream = LiveStream.from(e.pubkey, e.createdAt, e.tags) ?: continue
                    if (!(stream.hostPubkey in follows || e.pubkey in follows)) continue
                    if (stream.hostPubkey in blocked || !stream.isPlayableLive || !stream.isOnAirAt(now)) continue
                    val old = liveByAddress[stream.address]
                    if (old == null || old.createdAt < stream.createdAt) liveByAddress[stream.address] = stream
                    continue
                }
                if (e.pubkey !in follows || e.createdAt < since) continue

                when (e.kind) {
                    1, 6 -> {
                        posts++
                        postsBy[e.pubkey] = (postsBy[e.pubkey] ?: 0) + 1
                        if (e.kind == 1) {
                            notesById[e.id] = note(e)
                            for (tag in e.tags) {
                                if (tag.size < 2) continue
                                when (tag[0]) {
                                    "t" -> {
                                        val t = tag[1].trim().lowercase()
                                        if (t.isNotEmpty() && t.length <= 40) tagPeople.getOrPut(t) { HashSet() }.add(e.pubkey)
                                    }
                                    "q" -> likedBy.getOrPut(tag[1]) { HashSet() }.add(e.pubkey)
                                }
                            }
                            if (containsWavlakeTrack(e.content)) music.add(e)
                        } else {
                            lastETag(e.tags)?.let { likedBy.getOrPut(it) { HashSet() }.add(e.pubkey) }
                        }
                    }
                    7 -> if (e.content != "-") {
                        lastETag(e.tags)?.let { likedBy.getOrPut(it) { HashSet() }.add(e.pubkey) }
                    }
                    POLL_KIND -> polls.add(e)
                    ARTICLE_KIND -> if (RecipeTopics.matches(e.tags)) recipes.add(e) else articles.add(e)
                    DIVINE_KIND -> diVines.add(e)
                    in MarketListing.KINDS -> MarketListing.parse(e.id, e.pubkey, e.kind, e.content, e.createdAt, e.tags)
                        ?.let { listings.add(e to it) }
                }
            }

            val byCountThenId = compareByDescending<Ranked> { it.count }.thenBy { it.id }
            // Two people make a trend; one person's tag is just their tag.
            val trending = tagPeople.filter { it.value.size >= 2 }
                .map { Ranked(it.key, it.value.size) }.sortedWith(byCountThenId).take(10)
            val popular = likedBy.filter { it.value.size >= 2 }
                .map { PopularNote(it.key, it.value.size, notesById[it.key]) }
                .sortedWith(compareByDescending<PopularNote> { it.people }.thenBy { it.id }).take(3)

            // A listing edited twice in a day is still one listing.
            val listingAddresses = HashSet<String>()
            val uniqueListings = listings.sortedByDescending { it.first.createdAt }.filter { (e, _) ->
                val d = e.tags.firstOrNull { it.size >= 2 && it[0] == "d" }?.get(1) ?: e.id
                listingAddresses.add("${e.kind}:${e.pubkey}:$d")
            }

            fun tile(mode: FeedMode?, label: String, items: List<DashboardEvent>, preview: (DashboardEvent) -> String?): Tile? {
                val newest = items.maxByOrNull { it.createdAt } ?: return null
                return Tile(mode, label, items.size, preview(newest))
            }
            val title: (DashboardEvent) -> String? = { e ->
                firstTag("title", e.tags) ?: firstTag("alt", e.tags) ?: oneLine(e.content)
            }
            val tiles = listOfNotNull(
                tile(FeedMode.POLLS, FeedMode.POLLS.displayName, polls) { oneLine(it.content) },
                uniqueListings.firstOrNull()?.let { Tile(FeedMode.MARKETPLACE, FeedMode.MARKETPLACE.displayName, uniqueListings.size, it.second.title) },
                tile(FeedMode.ARTICLES, FeedMode.ARTICLES.displayName, articles, title),
                tile(FeedMode.REELS, FeedMode.REELS.displayName, diVines, title),
                tile(FeedMode.RECIPES, FeedMode.RECIPES.displayName, recipes, title),
                tile(FeedMode.MUSIC, FeedMode.MUSIC.displayName, music) { null },
            )

            // Sats: each receipt counted once; an unreadable invoice counts nothing.
            var sats = 0L
            val receiptIds = HashSet<String>()
            for (r in zapReceipts) {
                if (r.kind != ZAP_RECEIPT_KIND || r.createdAt < since || !receiptIds.add(r.id)) continue
                if (r.tags.none { it.size >= 2 && it[0] == "p" && it[1] == owner }) continue
                val bolt11 = firstTag("bolt11", r.tags) ?: continue
                sats += Bolt11.satsOrNull(bolt11) ?: continue
            }

            // The relay's ledger, not raw kind 3s: a refollow bot republishing
            // its list is not a new follower (#393).
            val newFollowers = followers?.current?.count { it.isNews && it.followedAt >= since } ?: 0

            return FeedDashboardSnapshot(
                posts = posts,
                activePeople = postsBy.size,
                satsReceived = sats,
                newFollowers = newFollowers,
                live = liveByAddress.values.sortedWith(
                    compareByDescending<LiveStream> { it.participants ?: 0 }.thenByDescending { it.createdAt },
                ),
                mostActive = postsBy.map { Ranked(it.key, it.value) }.sortedWith(byCountThenId),
                popular = popular,
                trending = trending,
                tiles = tiles,
            )
        }

        fun note(e: DashboardEvent): FeedNote = FeedNote.fromEvent(e.id, e.pubkey, e.content, e.tags, e.createdAt, e.kind)

        /** NIP-10: the last `e` tag is the one being replied or reacted to. */
        private fun lastETag(tags: List<List<String>>): String? =
            tags.lastOrNull { it.size >= 2 && it[0] == "e" && it[1].length == 64 }?.get(1)

        private fun firstTag(name: String, tags: List<List<String>>): String? =
            tags.firstOrNull { it.size >= 2 && it[0] == name && it[1].isNotEmpty() }?.get(1)

        private fun oneLine(text: String): String? =
            text.lineSequence().firstOrNull()?.trim()?.take(80)?.ifEmpty { null }

        private fun containsWavlakeTrack(content: String): Boolean =
            "wavlake.com" in content && content.split(Regex("\\s+")).any { WavlakeLink.trackId(it) != null }
    }
}
