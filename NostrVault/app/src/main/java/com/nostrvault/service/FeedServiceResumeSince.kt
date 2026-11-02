package com.nostrvault.service

import com.nostrvault.data.model.FeedMode
import com.nostrvault.data.model.NIP88Poll
import com.nostrvault.data.remote.WebSocketClient
import kotlinx.coroutines.launch

/**
 * Where a feed's REQ starts when the note list already holds that feed.
 *
 * The note list outlives a mode switch, so the REQ used to start at the oldest
 * note on screen: safe when the list is another feed's, but a cached feed
 * re-asked every relay for everything it already had (up to 500 notes each).
 * When the list is known to be this feed's, through to its newest note, only
 * what came after that is asked for. iOS: `feedSinceAndLimit` resumes from
 * `subscriptionRoundSince` the same way.
 *
 * [FeedService.feedNotesKey] names that feed ([currentFeedNotesKey]); it is set
 * when the feed's load finishes or its cache (filed after one) is put back, and
 * cleared whenever the list changes under it.
 */
internal object FeedResumeSince {
    /** Overlap with what we already have, for relay clock drift. Same as iOS. */
    const val OVERLAP_SEC = 60L

    /** Resume point in seconds for [newestSec], or null when there is nothing to resume from. */
    fun from(newestSec: Long?): Long? = newestSec?.takeIf { it > 0 }?.let { it - OVERLAP_SEC }

    /** Every connected relay has answered this round (and at least one has). */
    fun roundComplete(answered: Set<String>, connected: Set<String>): Boolean =
        answered.isNotEmpty() && answered.containsAll(connected)
}

/**
 * The feed as [FeedService.feedNotesKey] records it: [modeCacheKey] plus the
 * author set its REQ asked for. A follow, a grown Discover network or a new
 * trust graph changes the key, so the next REQ asks wide again and the new
 * authors' older notes come in.
 */
internal fun FeedService.currentFeedNotesKey(): String {
    val mode = _feedMode.value
    val authors = when {
        mode == FeedMode.DISCOVERY -> _extendedNetworkPubkeys.value.hashCode()
        isGlobalLikeMode() ->
            if (configStore.config.value.globalShowsEveryone) 0 else _wotPubkeys.value.hashCode()
        else -> _followedPubkeys.value.hashCode()
    }
    return "${modeCacheKey(mode)}#$authors"
}

/**
 * This round's resume point, or null to ask as before (a week back, or the
 * oldest note on screen). Frozen at the start of the round: relays connect at
 * different speeds, and a fast one's notes must not move the slow ones' start
 * past what only they have.
 */
internal fun FeedService.resumeSinceForRound(): Long? {
    val mode = _feedMode.value
    if (!FeedModeCaches.usesNotePipeline(mode) || feedNotesKey != currentFeedNotesKey()) return null
    val notes = _notes.value
    // The mention REQ keeps running under Polls, so only polls count there.
    val newest = if (mode == FeedMode.POLLS) {
        notes.filter { it.kind == NIP88Poll.KIND }.maxOfOrNull { it.createdAt.time }
    } else {
        notes.maxOfOrNull { it.createdAt.time }
    }
    return FeedResumeSince.from(newest?.div(1000))
}

/** The note list no longer stands for one feed through to its newest note. */
internal fun FeedService.forgetFeedNotesKey() {
    feedNotesKey = null
    roundSinceSec = null
    roundEoseRelays.clear()
}

/**
 * A relay finished this round's primary REQ. Once every connected feed relay
 * has, the list holds this feed through to its newest note and the next round
 * may resume from there. Waiting for all of them, not the first: the local
 * relay answers in milliseconds, and marking the feed whole then would have
 * the next round skip what only the slower relays hold.
 */
internal fun FeedService.notePrimaryEose(relayUrl: String) {
    if (!FeedModeCaches.usesNotePipeline(_feedMode.value) || _feedMode.value == FeedMode.POPULAR) return
    scope.launch {
        roundEoseRelays.add(relayUrl)
        val connected = feedClients.filterValues {
            it.connectionState.value == WebSocketClient.ConnectionState.CONNECTED
        }.keys
        if (FeedResumeSince.roundComplete(roundEoseRelays, connected)) feedNotesKey = currentFeedNotesKey()
    }
}
