package com.nostrvault.service

import com.nostrvault.data.model.FeedMode
import com.nostrvault.data.model.FeedNote
import com.nostrvault.data.model.PopularFilter
import com.nostrvault.data.model.RecipeTopics
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.jsonPrimitive

/**
 * Port of FeedFilterEngine.swift -- pure feed filtering and sorting.
 * No state, no UI dependencies. All inputs explicit.
 */
object FeedFilterEngine {

    /** NIP-23 long-form content. */
    private const val LONG_FORM_KIND = 30023

    /**
     * Parses the relay's `wot_cache.json` — haven-go's wotCache,
     * `{"pubkeys": {"<hex>": true, ...}, "timestamp": ...}` — into a pubkey
     * set. Returns null when the file can't be read as that shape (the caller
     * keeps whatever graph it had), and an empty set when the graph names
     * nobody but the owner: that carries no trust information, and treating
     * it as a graph would hide everyone from Global. Same rules as iOS's
     * FeedFilterEngine.loadWotPubkeys.
     *
     * Android used to decode this file as a bare JSON array, which always
     * threw, so the trust graph stayed empty and Global (Web of Trust on, the
     * default) and Discovery showed nothing.
     */
    fun parseWotCache(content: String, ownerHex: String): Set<String>? {
        val root = runCatching { Json.parseToJsonElement(content) }.getOrNull() ?: return null
        val pubkeys: Set<String> = when (root) {
            is JsonObject -> (root["pubkeys"] as? JsonObject)?.keys ?: return null
            // Tolerate a bare array too, in case an older relay ever wrote one.
            is JsonArray -> root.mapNotNull { runCatching { it.jsonPrimitive.content }.getOrNull() }.toSet()
            else -> return null
        }
        return if (hasUsableWot(pubkeys, ownerHex)) pubkeys else emptySet()
    }

    /** True when the graph names somebody other than the owner. */
    fun hasUsableWot(pubkeys: Set<String>, ownerHex: String): Boolean {
        if (pubkeys.isEmpty()) return false
        if (ownerHex.isEmpty()) return true
        return pubkeys.any { it != ownerHex }
    }

    /**
     * Whether a row would put a blocked person in front of the user (iOS #211).
     * `note.pubkey` alone misses most of it: a bare kind-6 repost carries the
     * reposter as its pubkey and shows the original author's post, an embedded
     * one has the original author as pubkey and the reposter in `repostedBy`,
     * and a reply shows the post it answers above itself.
     *
     * @param authorOf the author of a referenced event id, or null when it
     *   hasn't loaded. A bare repost falls back to its `p` tag.
     */
    fun involvesBlocked(
        note: FeedNote,
        blocked: Set<String>,
        authorOf: (String) -> String? = { null },
    ): Boolean {
        if (blocked.isEmpty()) return false
        if (note.pubkey in blocked) return true
        if (note.repostedBy != null && note.repostedBy in blocked) return true
        if (note.kind == 6 && note.repostedEventId != null) {
            val original = authorOf(note.repostedEventId)
                ?: note.tags.firstOrNull { it.size >= 2 && it[0] == "p" }?.get(1)
            if (original != null && original in blocked) return true
        }
        val parentAuthor = note.parentEventId?.let(authorOf)
        return parentAuthor != null && parentAuthor in blocked
    }

    /**
     * Main feed filter: applies blocked list, reply/repost visibility,
     * WoT membership, and popular scoring.
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
        globalLanguages: Set<String> = emptySet(),
        globalRequiresTrust: Boolean = true,
        /** Articles/Recipes on Global (trust rule) rather than Following. */
        longFormGlobal: Boolean = false,
        languageOf: (FeedNote) -> String? = { null },
        authorOf: (String) -> String? = { null },
    ): List<FeedNote> {
        // Articles and Recipes: Following keeps to follows; Global follows
        // the same Web of Trust / Everyone rule as Global, failing closed.
        fun longFormAdmits(pubkey: String): Boolean =
            if (longFormGlobal) !globalRequiresTrust || pubkey in wotPubkeys
            else pubkey in followedPubkeys
        var filtered = notes.filter { note ->
            // Always exclude blocked people, wherever the row would show them
            if (involvesBlocked(note, blocked, authorOf)) return@filter false

            // Exclude kind-6 reposts if disabled
            if (!showReposts && note.kind == 6) return@filter false

            // Exclude replies if disabled
            if (!showReplies && note.isReply) return@filter false

            // Spam filter
            if (note.isNoise) return@filter false

            // For reposts, membership is judged by the reposter (the follow who
            // boosted it), not the original author -- otherwise a repost of
            // someone you don't follow is silently dropped from the feed.
            val authorForMembership = note.repostedBy ?: note.pubkey

            when (mode) {
                FeedMode.FOLLOWING -> authorForMembership in followedPubkeys
                FeedMode.DISCOVERY -> authorForMembership !in followedPubkeys && authorForMembership in wotPubkeys
                FeedMode.GLOBAL -> {
                    // Web of Trust by default, judged on the note's author
                    // (iOS parity). Fails CLOSED: an empty graph means "not
                    // built yet", and admitting everyone then hands the open
                    // firehose to exactly the people who never chose it.
                    // "Everyone" (opted into behind a warning) skips the graph.
                    if (globalRequiresTrust && note.pubkey !in wotPubkeys) return@filter false
                    // Narrowed to chosen languages: notes whose language can't
                    // be told (short, links only) stay. See FeedLanguageDetector.
                    if (globalLanguages.isEmpty()) return@filter true
                    FeedLanguageDetector.admits(languageOf(note), globalLanguages)
                }
                FeedMode.POPULAR -> {
                    when (popularFilter) {
                        PopularFilter.ALL -> true
                        PopularFilter.FOLLOWS -> authorForMembership in followedPubkeys
                        PopularFilter.NON_FOLLOWS -> authorForMembership !in followedPubkeys
                    }
                }
                FeedMode.MEDIA -> note.mediaURLs.isNotEmpty()
                FeedMode.ARTICLES -> note.kind == LONG_FORM_KIND && longFormAdmits(note.pubkey)
                FeedMode.RECIPES -> note.kind == LONG_FORM_KIND && RecipeTopics.matches(note.tags) &&
                    !RecipeTopics.looksLikeTestPost(note.tags, note.content) &&
                    longFormAdmits(note.pubkey)
                // Live streams are not notes; LiveFeedService supplies them.
                FeedMode.LIVE -> false
                // Listings are not notes; MarketplaceFeedService supplies them.
                FeedMode.MARKETPLACE -> false
                // Music is Wavlake, not notes.
                FeedMode.MUSIC -> false
                // HashtagsFeedViewModel supplies these, not the note list.
                FeedMode.HASHTAGS -> false
                // Reels are served by ReelsFeedService, not the note list.
                FeedMode.REELS -> false
            }
        }

        // Sort: popular by score, everything else chronological
        filtered = if (mode == FeedMode.POPULAR && popularNoteScores.isNotEmpty()) {
            filtered.sortedByDescending { popularNoteScores[it.id] ?: 0.0 }
        } else {
            filtered.sortedByDescending { it.createdAt }
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
        globalRequiresTrust: Boolean = true,
        authorOf: (String) -> String? = { null },
    ): List<FeedNote> {
        var filtered = notes.filter { note ->
            if (involvesBlocked(note, blocked, authorOf)) return@filter false
            // Web-of-trust scoping applies only to Global media (matches iOS
            // FeedFilterEngine.filterMediaNotes). Following media is already scoped
            // to followed authors by the subscription, so it shows all media here —
            // gating it on wotPubkeys (often empty in Following mode) hid everything.
            // "Everyone" lifts it, as on iOS (#133).
            if (isGlobalMedia && globalRequiresTrust && wotPubkeys.isNotEmpty() && note.pubkey !in wotPubkeys) return@filter false
            if (note.mediaURLs.isEmpty()) return@filter false
            if (note.isNoise) return@filter false
            true
        }.sortedByDescending { it.createdAt }

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
