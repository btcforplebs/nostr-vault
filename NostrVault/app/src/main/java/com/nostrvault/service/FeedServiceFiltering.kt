package com.nostrvault.service

import com.nostrvault.data.model.*
import com.nostrvault.relay.HavenConfig
import kotlinx.coroutines.*
import kotlinx.coroutines.flow.*
import kotlinx.serialization.json.*

    /** The Following / Global scope for Articles, Recipes and Polls; null elsewhere. */
    internal fun FeedService.longFormScope(): MediaFeedMode? = when (_feedMode.value) {
        FeedMode.ARTICLES -> _articlesFeedMode.value
        FeedMode.RECIPES -> _recipesFeedMode.value
        FeedMode.POLLS -> _pollsFeedMode.value
        else -> null
    }

    internal fun FeedService.doRecomputeFilteredNotes() {
        val config = configStore.config.value
        val blockedPubkeys = config.blockedForActiveAccount()
            .mapNotNull { nostrService.npubToHex(it) }.toSet()

        _filteredNotes.value = filterForCurrentFeed(_notes.value, config, blockedPubkeys)

        _filteredMediaNotes.value = feedFilterEngine.filterMediaNotes(
            notes = _notes.value,
            blocked = blockedPubkeys,
            wotPubkeys = myWeb(),
            isGlobalMedia = _mediaFeedMode.value == MediaFeedMode.GLOBAL,
            globalRequiresTrust = !config.globalShowsEveryone,
            authorOf = ::authorOf,
        )

        _parentIsNextNote.value = feedFilterEngine.computeParentIsNext(_filteredNotes.value)
    }

    internal fun FeedService.filterForCurrentFeed(
        notes: List<FeedNote>,
        config: HavenConfig,
        blockedPubkeys: Set<String>,
    ): List<FeedNote> = feedFilterEngine.filterFeedNotes(
        notes = notes,
        mode = _feedMode.value,
        blocked = blockedPubkeys,
        showReposts = configStore.config.value.showReposts,
        showReplies = configStore.config.value.showReplies,
        followedPubkeys = _followedPubkeys.value.toSet(),
        wotPubkeys = myWeb(),
        popularFilter = _popularFilter.value,
        popularNoteScores = _popularNoteScores.value,
        globalLanguages = config.globalFeedLanguages.toSet(),
        globalRequiresTrust = !config.globalShowsEveryone,
        longFormGlobal = longFormScope() == MediaFeedMode.GLOBAL,
        pollStatus = _pollStatusFilter.value,
        languageOf = ::languageOf,
        authorOf = ::authorOf,
    )

    /** The saved web plus your follows, so Global shows a new follow at once. */
    private fun FeedService.myWeb(): Set<String> = TrustMap.web(_wotPubkeys.value, _followedPubkeys.value.toSet())

    /** Author of a note the feed has loaded, for the blocked-person check. */
    internal fun FeedService.authorOf(id: String): String? = findNote(id)?.pubkey

    private fun FeedService.languageOf(note: FeedNote): String? {
        noteLanguageCache[note.id]?.let { return it.ifEmpty { null } }
        // Bounded well above the feed cap; a reset just re-detects.
        if (noteLanguageCache.size > 4000) noteLanguageCache.clear()
        val detected = FeedLanguageDetector.detect(FeedLanguageDetector.text(note.content, note.kind))
        noteLanguageCache[note.id] = detected ?: ""
        return detected
    }

    internal fun FeedService.isGlobalLikeMode(): Boolean =
        _feedMode.value == FeedMode.GLOBAL ||
            (_feedMode.value == FeedMode.MEDIA && _mediaFeedMode.value == MediaFeedMode.GLOBAL) ||
            longFormScope() == MediaFeedMode.GLOBAL

    /**
     * Articles and Recipes ask for follows on Following, and for the trust
     * graph on Global (capped at 500 like Media); Everyone asks for anyone.
     */
    internal fun FeedService.appendLongFormAuthors(sb: StringBuilder, relayUrl: String) {
        val authors = when (longFormScope()) {
            MediaFeedMode.FOLLOWING -> followAuthors(relayUrl).take(500)
            MediaFeedMode.GLOBAL ->
                if (configStore.config.value.globalShowsEveryone) emptyList()
                else _wotPubkeys.value.take(500).toList()
            null -> emptyList()
        }
        if (authors.isNotEmpty()) {
            sb.append(",\"authors\":[${authors.joinToString(",") { "\"$it\"" }}]")
        }
    }
