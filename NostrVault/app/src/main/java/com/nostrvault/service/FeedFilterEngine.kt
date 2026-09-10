package com.nostrvault.service

import com.nostrvault.data.model.FeedMode
import com.nostrvault.data.model.FeedNote
import com.nostrvault.data.model.PopularFilter

/**
 * Port of FeedFilterEngine.swift -- pure feed filtering and sorting.
 * No state, no UI dependencies. All inputs explicit.
 */
object FeedFilterEngine {

    /**
     * Main feed filter: applies blocked list, reply/repost visibility,
     * WoT membership, popular scoring, and throttle limits.
     */
    fun filterFeedNotes(
        notes: List<FeedNote>,
        mode: FeedMode,
        blocked: Set<String>,
        showReposts: Boolean,
        showReplies: Boolean,
        followedPubkeys: Set<String>,
        wotPubkeys: Set<String>,
        popularFilter: PopularFilter = PopularFilter.ALL,
        popularNoteScores: Map<String, Double> = emptyMap(),
        throttledPubkeys: Map<String, Int> = emptyMap(),
    ): List<FeedNote> {
        var filtered = notes.filter { note ->
            // Always exclude blocked pubkeys
            if (note.pubkey in blocked) return@filter false
            if (note.repostedBy != null && note.repostedBy in blocked) return@filter false

            // Exclude kind-6 reposts if disabled
            if (!showReposts && note.kind == 6) return@filter false

            // Exclude replies if disabled
            if (!showReplies && note.isReply) return@filter false

            // Spam filter
            if (FeedNote.isNoiseOrSpam(note.content, note.tags)) return@filter false

            // For reposts, membership is judged by the reposter (the follow who
            // boosted it), not the original author -- otherwise a repost of
            // someone you don't follow is silently dropped from the feed.
            val authorForMembership = note.repostedBy ?: note.pubkey

            when (mode) {
                FeedMode.FOLLOWING -> authorForMembership in followedPubkeys
                FeedMode.DISCOVERY -> authorForMembership !in followedPubkeys && authorForMembership in wotPubkeys
                FeedMode.GLOBAL -> true
                FeedMode.POPULAR -> {
                    when (popularFilter) {
                        PopularFilter.ALL -> true
                        PopularFilter.FOLLOWS -> authorForMembership in followedPubkeys
                        PopularFilter.NON_FOLLOWS -> authorForMembership !in followedPubkeys
                    }
                }
                FeedMode.MEDIA -> note.mediaURLs.isNotEmpty()
            }
        }

        // Sort: popular by score, everything else chronological
        filtered = if (mode == FeedMode.POPULAR && popularNoteScores.isNotEmpty()) {
            filtered.sortedByDescending { popularNoteScores[it.id] ?: 0.0 }
        } else {
            filtered.sortedByDescending { it.createdAt }
        }

        // Apply throttle limits per author
        if (throttledPubkeys.isNotEmpty()) {
            val authorCounts = mutableMapOf<String, Int>()
            filtered = filtered.filter { note ->
                val limit = throttledPubkeys[note.pubkey] ?: return@filter true
                val count = authorCounts.getOrPut(note.pubkey) { 0 }
                if (count >= limit) return@filter false
                authorCounts[note.pubkey] = count + 1
                true
            }
        }

        return filtered
    }

    /**
     * Filter notes for the media gallery grid.
     */
    fun filterMediaNotes(
        notes: List<FeedNote>,
        blocked: Set<String>,
        wotPubkeys: Set<String>,
        isGlobalMedia: Boolean,
        throttledPubkeys: Map<String, Int> = emptyMap(),
    ): List<FeedNote> {
        var filtered = notes.filter { note ->
            if (note.pubkey in blocked) return@filter false
            if (note.mediaURLs.isEmpty()) return@filter false
            if (FeedNote.isNoiseOrSpam(note.content, note.tags)) return@filter false
            if (isGlobalMedia) true else note.pubkey in wotPubkeys
        }.sortedByDescending { it.createdAt }

        if (throttledPubkeys.isNotEmpty()) {
            val authorCounts = mutableMapOf<String, Int>()
            filtered = filtered.filter { note ->
                val limit = throttledPubkeys[note.pubkey] ?: return@filter true
                val count = authorCounts.getOrPut(note.pubkey) { 0 }
                if (count >= limit) return@filter false
                authorCounts[note.pubkey] = count + 1
                true
            }
        }

        return filtered
    }

    /**
     * Detect parent/child note pairs for UI collapse opportunities.
     * Returns a set of note IDs whose parent is the immediately preceding note.
     */
    fun computeParentIsNext(filteredNotes: List<FeedNote>): Set<String> {
        val result = mutableSetOf<String>()
        for (i in 0 until filteredNotes.size - 1) {
            val note = filteredNotes[i]
            val next = filteredNotes[i + 1]
            if (note.parentEventId == next.id) {
                result.add(note.id)
            }
        }
        return result
    }

    /**
     * Normalize a relay URL for deduplication.
     * Strips scheme, trailing slashes, lowercases.
     */
    fun normalizeRelayKey(url: String): String =
        url.lowercase()
            .removePrefix("wss://")
            .removePrefix("ws://")
            .removePrefix("https://")
            .removePrefix("http://")
            .trimEnd('/')
}
