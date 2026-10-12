package com.nostrvault.service

import java.util.Date

/**
 * Search tab's "For you": recommendations judged only from what the user's
 * own relay already holds — its trust graph and the notes in the feed. No
 * recommendation server is asked. Port of iOS `SearchRecommendations`.
 */
object SearchRecommendations {
    /** Someone you don't follow, and how many of your follows follow them. */
    data class Person(val pubkey: String, val vouches: Int)

    /** Below this many of your follows, a follow-of-a-follow is noise. */
    const val MIN_VOUCHES = 2

    /**
     * People your follows follow most, from the relay graph's [vouches]
     * (pubkey → how many of your follows follow them). Drops you, anyone you
     * already follow and anyone blocked. Most vouched first, ties by pubkey
     * so the list doesn't reshuffle between refreshes.
     */
    fun people(
        vouches: Map<String, Int>,
        following: Set<String>,
        owner: String,
        blocked: Set<String>,
        limit: Int = 8,
    ): List<Person> =
        vouches.entries
            .filter { it.value >= MIN_VOUCHES && it.key != owner && it.key !in following && it.key !in blocked }
            .sortedWith(compareByDescending<Map.Entry<String, Int>> { it.value }.thenBy { it.key })
            .take(limit)
            .map { Person(it.key, it.value) }

    /**
     * Your interests: the hashtags you follow, then the ones on notes you
     * wrote or reacted to (each a note's tag array), most used first. Many
     * people never follow a hashtag, and what they post and like says the
     * same thing.
     */
    fun interests(followed: List<String>, engaged: List<List<List<String>>>, limit: Int = 12): List<String> {
        val out = LinkedHashSet<String>()
        for (tag in followed) {
            val name = InterestList.normalize(tag)
            if (name.isNotEmpty()) out.add(name)
        }
        val rest = HashtagSuggestions.top(engaged, out, limit = maxOf(0, limit - out.size))
        return (out.toList() + rest).take(limit)
    }

    /** A note as the picker sees it. */
    data class Candidate(
        val id: String,
        val pubkey: String,
        val tags: List<List<String>>,
        val createdAt: Date,
    )

    /**
     * Notes tagged with one of your [interests] (followed hashtags), not
     * yours, not blocked. Ranked by how many interests a note hits, then by
     * how close its author is to you (followed, else vouches), then newest.
     * At most one note per author, so one prolific poster can't fill it.
     * Notes in [seen] (ones you already reacted to) are left out.
     */
    fun notes(
        candidates: List<Candidate>,
        interests: Set<String>,
        following: Set<String>,
        vouches: Map<String, Int>,
        owner: String,
        blocked: Set<String>,
        seen: Set<String> = emptySet(),
        limit: Int = 5,
    ): List<String> {
        val wanted = interests.map(InterestList::normalize).filter { it.isNotEmpty() }.toSet()
        if (wanted.isEmpty()) return emptyList()

        class Scored(val id: String, val pubkey: String, val hits: Int, val closeness: Int, val createdAt: Date)
        // Followed authors outrank anyone the graph knows of.
        val followedCloseness = Int.MAX_VALUE

        val scored = ArrayList<Scored>()
        for (note in candidates) {
            if (note.pubkey == owner || note.pubkey in blocked || note.id in seen) continue
            val hit = HashSet<String>()
            for (tag in note.tags) {
                if (tag.size < 2 || tag[0] != "t") continue
                val name = InterestList.normalize(tag[1])
                if (name in wanted) hit.add(name)
            }
            if (hit.isEmpty()) continue
            val closeness = if (note.pubkey in following) followedCloseness else vouches[note.pubkey] ?: 0
            scored.add(Scored(note.id, note.pubkey, hit.size, closeness, note.createdAt))
        }
        scored.sortWith(
            compareByDescending<Scored> { it.hits }
                .thenByDescending { it.closeness }
                .thenByDescending { it.createdAt }
                .thenBy { it.id },
        )
        val authors = HashSet<String>()
        val out = ArrayList<String>()
        for (note in scored) {
            if (!authors.add(note.pubkey)) continue
            out.add(note.id)
            if (out.size == limit) break
        }
        return out
    }
}
