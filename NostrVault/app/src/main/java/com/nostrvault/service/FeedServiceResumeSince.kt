package com.nostrvault.service

import com.nostrvault.data.model.FeedMode
import com.nostrvault.data.model.isLocalDvm
import com.nostrvault.data.model.NIP88Poll
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
 * cleared whenever the list changes under it. Only the relays that answered
 * that load ([FeedService.feedNotesRelays]) resume; any other relay asks wide.
 */
internal object FeedResumeSince {
    /** Overlap with what we already have, for relay clock drift. Same as iOS. */
    const val OVERLAP_SEC = 60L

    /** Resume point in seconds for [newestSec], or null when there is nothing to resume from. */
    fun from(newestSec: Long?): Long? = newestSec?.takeIf { it > 0 }?.let { it - OVERLAP_SEC }

    /**
     * Every relay of the round, as frozen at its start, has answered or
     * failed to connect, and at least one answered. A relay still waiting
     * out its stagger or its handshake holds the round open.
     */
    fun roundComplete(round: Set<String>, answered: Set<String>, failed: Set<String>): Boolean =
        round.isNotEmpty() && answered.any { it in round } && round.all { it in answered || it in failed }
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
    feedNotesRelays.clear()
    roundSinceSec = null
    roundResumeRelays.clear()
    roundEoseRelays.clear()
    roundRelays.clear()
    roundFailedRelays.clear()
}

/**
 * A new round of the primary REQ goes to [relayUrls]: only they decide when
 * it is complete. Call after [roundSinceSec] is set for the round.
 */
internal fun FeedService.startResumeRound(relayUrls: Collection<String>) {
    roundResumeRelays.clear()
    if (roundSinceSec != null) roundResumeRelays.addAll(feedNotesRelays)
    roundEoseRelays.clear()
    roundFailedRelays.clear()
    roundRelays.clear()
    roundRelays.addAll(relayUrls)
}

/** A round relay's dial failed: it will not answer this round, so it no longer holds it open. */
internal fun FeedService.notePrimaryRelayFailed(relayUrl: String) {
    if (relayUrl !in roundRelays) return
    roundFailedRelays.add(relayUrl)
    markRoundIfComplete()
}

private fun FeedService.markRoundIfComplete() {
    val mode = _feedMode.value
    if (!FeedModeCaches.usesNotePipeline(mode) || mode.isLocalDvm) return
    if (FeedResumeSince.roundComplete(roundRelays, roundEoseRelays, roundFailedRelays)) {
        feedNotesKey = currentFeedNotesKey()
        // A relay that failed this round missed what came since: it asks wide next time.
        feedNotesRelays.clear()
        feedNotesRelays.addAll(roundEoseRelays)
    }
}

/**
 * A relay finished this round's primary REQ. Once every relay the round
 * started with has answered or failed to connect, the list holds this feed
 * through to its newest note and the next round may resume from there.
 * The set is frozen at the round's start, not read from what is connected
 * now: the local relay answers in milliseconds while the remotes are still
 * waiting out their stagger, and marking the feed whole then would have the
 * next round skip what only they hold.
 */
internal fun FeedService.notePrimaryEose(relayUrl: String) {
    scope.launch {
        if (relayUrl !in roundRelays) return@launch
        roundEoseRelays.add(relayUrl)
        markRoundIfComplete()
    }
}
