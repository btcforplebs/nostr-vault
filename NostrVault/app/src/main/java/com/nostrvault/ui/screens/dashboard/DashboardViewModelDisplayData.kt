package com.nostrvault.ui.screens.dashboard

import android.util.Log
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.material3.*
import androidx.compose.runtime.*
import kotlinx.coroutines.launch
import kotlinx.coroutines.delay
import androidx.lifecycle.viewModelScope
import com.nostrvault.data.model.*
import com.nostrvault.service.NostrEvent
import com.nostrvault.ui.theme.*
import com.nostrvault.util.RelayGiven
import kotlinx.coroutines.*
import kotlinx.coroutines.flow.map
import kotlinx.coroutines.sync.withLock
import kotlinx.serialization.json.*
import com.nostrvault.ui.screens.dashboard.DashboardViewModel.Companion.TAG

    internal fun DashboardViewModel.armZapsSettle() {
        zapsSettleJob?.cancel()
        zapsSettleJob = viewModelScope.launch {
            delay(6000)
            _zapsHasLoadedOnce.value = true
        }
    }

    /**
     * Likes gets the same bounded settle: an empty list stops showing
     * "Loading likes…" after 5 s even if a relay never answers.
     * iOS updateLikesSettleState.
     */
    internal fun DashboardViewModel.armLikesSettle() {
        likesSettleJob?.cancel()
        likesSettleJob = viewModelScope.launch {
            delay(5000)
            _likesHasLoadedOnce.value = true
        }
    }

    internal fun DashboardViewModel.scheduleUpdateDisplayData() {
        updateJob?.cancel()
        updateGeneration++
        val gen = updateGeneration
        // Longer debounce during the initial stored-event burst; 150ms (matching
        // iOS) once live. EOSE bypasses this entirely via handleEOSE().
        val debounceMs = if (!_notesHasLoadedOnce.value) 500L else 150L
        updateJob = viewModelScope.launch {
            delay(debounceMs)
            if (gen != updateGeneration) return@launch
            updateDisplayData(gen)
            // Likes and zaps that arrive later name more missing posts; ask
            // for those too (iOS re-asks on every events change). Ids already
            // asked for are skipped.
            when (_viewMode.value) {
                VaultViewMode.LIKES -> if (_likesFilter.value == VaultLikesFilter.MY_LIKES) fetchMissingLikedNotes()
                VaultViewMode.ZAPS -> if (_zapsFilter.value == VaultZapsFilter.MY_ZAPS) fetchMissingZappedNotes()
                else -> {}
            }
        }
    }

    /**
     * Rebuilds the shown list, then tells a waiting filter note it landed. Every
     * path goes through here: the debounced one, EOSE and the snapshot restore.
     */
    internal suspend fun DashboardViewModel.updateDisplayData(gen: Int) {
        rebuildDisplayData(gen)
        if (gen == updateGeneration) _displayPass.value++
    }

    private suspend fun DashboardViewModel.rebuildDisplayData(gen: Int) = withContext(Dispatchers.Default) {
        val currentMode = _viewMode.value
        val events = allEventsMutex.withLock { allEvents.toList() }
        val owner = nostrService.activeHexPubkey
        val whitelist = resolveWhitelistedHexPubkeys()
        val trusted = feedService.relayTabTrustedPubkeys()
        val blocked = configStore.config.value.blockedForActiveAccount()
            .mapNotNull { nostrService.npubToHex(it) }.toSet()

        // Partition once instead of re-scanning the full list per kind.
        // allEvents can hold one event twice (history pages query outbox and
        // inbox, and the snapshot is saved from allEvents); the lists key on
        // id, and a duplicate key crashes the LazyColumn.
        val noteEvents = ArrayList<NostrEvent>(events.size)
        val reactionEvents = ArrayList<NostrEvent>()
        val zapEvents = ArrayList<NostrEvent>()
        val partitionedIds = HashSet<String>(events.size * 2)
        for (event in events) {
            if (!partitionedIds.add(event.id)) continue
            when (event.kind) {
                in RELAY_TAB_NOTE_KINDS -> noteEvents.add(event)
                7 -> reactionEvents.add(event)
                9735 -> zapEvents.add(event)
            }
        }
        if (dotSeenAt.isNotEmpty()) {
            val newest = VaultDots.newest(events.map { it.kind to it.createdAt }, RELAY_TAB_NOTE_KINDS, System.currentTimeMillis() / 1000)
            withContext(Dispatchers.Main) { refreshDots(newest) }
        }

        when (currentMode) {
            // Followers come from the relay's follower ledger, not these events.
            VaultViewMode.FOLLOWERS -> Unit
            VaultViewMode.NOTES -> {
                val currentFilter = _contentFilter.value
                val scopeKinds = _noteScope.value.kinds(RELAY_TAB_NOTE_KINDS)
                val recipesOnly = _noteScope.value == VaultNoteScope.ARTICLES && _recipesOnly.value

                val filtered = noteEvents.filter { event ->
                    // Log all events before kind filtering to see what we're dropping
                    val hasUserPTag = event.tags.any { it.size >= 2 && it[0] == "p" && it[1] == owner }
                    if (hasUserPTag && event.pubkey != owner) {
                        Log.d(TAG, "Event with user p-tag BEFORE filter: id=${event.id.take(8)}, kind=${event.kind}, from=${event.pubkey.take(8)}")
                    }

                    if (event.kind !in RELAY_TAB_NOTE_KINDS) {
                        if (hasUserPTag && event.pubkey != owner) {
                            Log.w(TAG, "DROPPING event kind ${event.kind} that tags user: id=${event.id.take(8)}")
                        }
                        return@filter false
                    }
                    // Articles and highlights are listed apart in the Vault tab.
                    if (event.kind !in scopeKinds) return@filter false
                    if (recipesOnly && !VaultNoteScope.isRecipe(event.tags)) return@filter false

                    if (event.pubkey in blocked) return@filter false

                    val isMine = event.pubkey == owner
                    val isTagged = event.tags.any { it.size >= 2 && it[0] == "p" && it[1] == owner }
                    val isOutside = isTagged &&
                        VaultContentFilter.isOutside(event.pubkey, owner, whitelist, trusted)
                    when (currentFilter) {
                        VaultContentFilter.ALL -> {
                            val isWhitelisted = whitelist.contains(event.pubkey)
                            (isMine || isTagged || isWhitelisted) && !isOutside
                        }
                        VaultContentFilter.MINE -> isMine
                        VaultContentFilter.OUTSIDE -> isOutside
                        VaultContentFilter.TAGGED -> {
                            val tagged = !isMine && isTagged && !isOutside
                            if (tagged) {
                                Log.d(TAG, "TAGGED note included: id=${event.id.take(8)}, from=${event.pubkey.take(8)}, kind=${event.kind}")
                            }
                            tagged
                        }
                    }
                }.sortedByDescending { it.createdAt }
                    .let { VaultRepostDedupe.apply(it, owner, whitelist) }

                Log.d(TAG, "NOTES mode: filter=${currentFilter.displayName}, total=${filtered.size} notes, maxDisplayedItems=$maxDisplayedItems")
                notesFilteredCount = filtered.size

                // Articles and Highlights are short and page by button, so
                // nothing loaded may sit hidden under a cap with no way to
                // reveal it: they list every row they have.
                val cap = if (_noteScope.value.pagesByButton) Int.MAX_VALUE else maxDisplayedItems

                // Convert to FeedNote for display
                // Reposts and your own notes skip the spam filter: iOS filters
                // neither, and a bare repost has no text of its own to judge.
                // A bare repost shows its original when the vault has it.
                val loadedById = noteEvents.associateBy { it.id }
                val displaySlice = filtered.take(cap).map { event ->
                    val note = FeedNote.fromEvent(event.id, event.pubkey, event.content, event.tags, event.createdAt, event.kind)
                    val original = note.repostedEventId?.takeIf { note.isBareRepost }
                        ?.let { loadedById[it] }?.takeIf { it.kind != 6 }
                        ?.let { FeedNote.fromEvent(it.id, it.pubkey, it.content, it.tags, it.createdAt, it.kind) }
                    when {
                        original != null -> note.withRepostedOriginal(original)
                        // Credited, like the feed does, to the author its `p` tag names.
                        note.isBareRepost -> note.copy(
                            pubkey = note.tags.firstOrNull { it.size >= 2 && it[0] == "p" }?.get(1) ?: note.pubkey,
                            repostedBy = note.pubkey,
                        )
                        else -> note
                    }
                }.filter { it.kind == 6 || it.publisher == owner || !it.isNoiseOrSpam() }
                // Reposts are headed by the reposter but show the original's author.
                displaySlice.filter { it.repostedBy != null }
                    .flatMap { listOf(it.pubkey, it.repostedBy!!) }
                    .distinct()
                    .takeIf { it.isNotEmpty() }
                    ?.let { nostrService.fetchMissingProfiles(it) }

                val droppedBySpamFilter = (filtered.size.coerceAtMost(cap)) - displaySlice.size
                if (droppedBySpamFilter > 0) {
                    Log.w(TAG, "Spam filter dropped $droppedBySpamFilter notes")
                }
                if (filtered.size > cap) {
                    Log.w(TAG, "Display limit: showing ${cap} of ${filtered.size} filtered notes (${filtered.size - cap} hidden)")
                }

                val displayedIds = displaySlice.map { it.id }.toSet()

                // Build reaction map for displayed notes
                val rxMap = mutableMapOf<String, MutableList<Pair<String, String>>>()
                val latestReaction = mutableMapOf<String, Long>()
                for (event in reactionEvents) {
                    val targetId = event.tags.firstOrNull { it.size >= 2 && it[0] == "e" && displayedIds.contains(it[1]) }?.get(1) ?: continue
                    val emoji = if (event.content.isEmpty()) "+" else event.content
                    rxMap.getOrPut(targetId) { mutableListOf() }.add(Pair(event.pubkey, emoji))
                    val existing = latestReaction[targetId]
                    if (existing == null || event.createdAt > existing) {
                        latestReaction[targetId] = event.createdAt
                    }
                }

                // Build zap map for displayed notes
                // A zap receipt is signed by the wallet server, so the relay's
                // block list never catches it: the zapper is checked here.
                val noteZaps = zapEvents.mapNotNull { event ->
                    val targetId = event.tags.firstOrNull { it.size >= 2 && it[0] == "e" && displayedIds.contains(it[1]) }?.get(1)
                        ?: return@mapNotNull null
                    val parsed = parseZapReceipt(event) ?: return@mapNotNull null
                    VaultZapsReceived.Receipt(parsed.copy(targetNoteId = targetId), event.createdAt)
                }
                val zMap = VaultZapsReceived.build(
                    receipts = noteZaps,
                    myNoteIds = displayedIds,
                    owner = owner,
                    isBlocked = { it in blocked },
                    excludeOwner = false,
                ).zappers

                // Build repost map (kind 6 e-tagging a displayed note) and quote map
                // (kind 1 q-tagging a displayed note). Mirrors iOS VaultDataProcessing
                // so reposts/quotes of your note appear in the engagement bar.
                val rpMap = mutableMapOf<String, MutableList<String>>()
                val qtMap = mutableMapOf<String, MutableList<String>>()
                for (event in noteEvents) {
                    when (event.kind) {
                        6 -> {
                            val targetId = event.tags.firstOrNull { it.size >= 2 && it[0] == "e" && displayedIds.contains(it[1]) }?.get(1) ?: continue
                            rpMap.getOrPut(targetId) { mutableListOf() }.add(event.pubkey)
                        }
                        1 -> {
                            val targetId = event.tags.firstOrNull { it.size >= 2 && it[0] == "q" && displayedIds.contains(it[1]) }?.get(1) ?: continue
                            qtMap.getOrPut(targetId) { mutableListOf() }.add(event.pubkey)
                        }
                    }
                }

                if (gen != updateGeneration) return@withContext
                withContext(Dispatchers.Main.immediate) {
                    _displayNotes.value = displaySlice
                    _reactionMap.value = rxMap
                    _zapMap.value = zMap
                    _latestReactionDates.value = latestReaction
                    _repostMap.value = rpMap
                    _quoteMap.value = qtMap
                    _notesHasLoadedOnce.value = true
                    _connectionStatus.value = "Local (${displaySlice.size})"
                }
            }

            VaultViewMode.LIKES -> {
                val currentLikesFilter = _likesFilter.value

                if (currentLikesFilter == VaultLikesFilter.MY_LIKES) {
                    // My Likes: notes I reacted to
                    val myLikeDates = mutableMapOf<String, Long>()
                    for (event in reactionEvents) {
                        if (event.pubkey != owner) continue
                        val targetId = event.tags.firstOrNull { it.size >= 2 && it[0] == "e" }?.get(1) ?: continue
                        val existing = myLikeDates[targetId]
                        if (existing == null || event.createdAt > existing) {
                            myLikeDates[targetId] = event.createdAt
                        }
                    }

                    val myLikedNoteIds = myLikeDates.keys
                    val filtered = noteEvents
                        .filter { myLikedNoteIds.contains(it.id) }
                        .sortedByDescending { myLikeDates[it.id] ?: 0L }

                    val displaySlice = filtered.take(maxDisplayedItems).map { event ->
                        FeedNote.fromEvent(event.id, event.pubkey, event.content, event.tags, event.createdAt, event.kind)
                    }

                    if (gen != updateGeneration) return@withContext
                    withContext(Dispatchers.Main.immediate) {
                        _displayLikedNotes.value = displaySlice
                        _reactionMap.value = emptyMap()
                        _latestReactionDates.value = emptyMap()
                        if (displaySlice.isNotEmpty()) _likesHasLoadedOnce.value = true
                    }
                } else {
                    // Incoming reactions on target note sets
                    // Received: reactions others left on my notes.
                    val targetNoteIds: Set<String> =
                        noteEvents.filter { it.pubkey == owner }.map { it.id }.toSet()

                    val rxMap = mutableMapOf<String, MutableList<Pair<String, String>>>()
                    val latestReaction = mutableMapOf<String, Long>()

                    for (event in reactionEvents) {
                        if (event.pubkey == owner) continue
                        val targetId = event.tags.firstOrNull {
                            it.size >= 2 && it[0] == "e" && targetNoteIds.contains(it[1])
                        }?.get(1) ?: continue
                        val emoji = if (event.content.isEmpty()) "+" else event.content
                        rxMap.getOrPut(targetId) { mutableListOf() }.add(Pair(event.pubkey, emoji))
                        val existing = latestReaction[targetId]
                        if (existing == null || event.createdAt > existing) {
                            latestReaction[targetId] = event.createdAt
                        }
                    }

                    val likedNoteIds = rxMap.keys
                    val filtered = noteEvents
                        .filter { likedNoteIds.contains(it.id) }
                        .sortedWith(compareByDescending<NostrEvent> { latestReaction[it.id] ?: 0L }
                            .thenByDescending { it.createdAt })

                    val displaySlice = filtered.take(maxDisplayedItems).map { event ->
                        FeedNote.fromEvent(event.id, event.pubkey, event.content, event.tags, event.createdAt, event.kind)
                    }

                    if (gen != updateGeneration) return@withContext
                    withContext(Dispatchers.Main.immediate) {
                        _displayLikedNotes.value = displaySlice
                        _reactionMap.value = rxMap
                        _latestReactionDates.value = latestReaction
                        if (displaySlice.isNotEmpty()) _likesHasLoadedOnce.value = true
                    }
                }
            }

            VaultViewMode.ZAPS -> {
                val currentZapsFilter = _zapsFilter.value

                // Parse all zap receipts (with caching)
                data class ParsedEntry(val receiptId: String, val parsed: ParsedZapReceipt)
                val parsedReceipts = mutableListOf<ParsedEntry>()
                for (receipt in zapEvents) {
                    val parsed = parseZapReceipt(receipt) ?: continue
                    parsedReceipts.add(ParsedEntry(receipt.id, parsed))
                }

                // Both lists run newest zap first: a post moves to the top
                // when a zap on it comes in (iOS #296).
                val receiptTimes = zapEvents.associate { it.id to it.createdAt }

                if (currentZapsFilter == VaultZapsFilter.MY_ZAPS) {
                    val myReceipts = parsedReceipts
                        .filter { it.parsed.senderPubkey == owner && it.parsed.requestIsSigned }
                    // Receipts on the relays, plus what this app recorded
                    // zapping from this phone.
                    // Stream and profile zaps record a non-note key; only event ids count.
                    val locallyZapped = feedService.zappedEventIds.value.filterKeys(RelayGiven::isEventId)
                    val myZappedNoteIds = myReceipts.mapNotNull { it.parsed.targetNoteId }.toSet() + locallyZapped.keys
                    val wallet = walletGiven

                    // The wallet's history, then anything only a receipt or
                    // this app's own list knows about.
                    val seen = wallet.notes.map { it.id }.toHashSet()
                    val candidates = wallet.notes + noteEvents
                        .filter { myZappedNoteIds.contains(it.id) && seen.add(it.id) }
                        .map { event -> FeedNote.fromEvent(event.id, event.pubkey, event.content, event.tags, event.createdAt, event.kind) }
                    val lastZapAt = RelayGiven.lastZapTimes(
                        wallet.times,
                        myReceipts.mapNotNull { item ->
                            val id = item.parsed.targetNoteId ?: return@mapNotNull null
                            id to (receiptTimes[item.receiptId] ?: return@mapNotNull null)
                        },
                    )
                    val filtered = RelayGiven.newestZapFirst(candidates, lastZapAt, { it.id }, { it.createdAt.time / 1000 })
                    val displaySlice = filtered.take(maxDisplayedItems)
                    val givenMap = RelayGiven.givenAmounts(locallyZapped, wallet.amounts)
                        .mapValues { (_, sats) -> listOf(owner to sats) }

                    if (gen != updateGeneration) return@withContext
                    withContext(Dispatchers.Main.immediate) {
                        _displayZappedNotes.value = displaySlice
                        _zapMap.value = givenMap
                        if (displaySlice.isNotEmpty()) _zapsHasLoadedOnce.value = true
                    }
                } else {
                    // Incoming zaps on target note sets
                    // Received: zaps others sent to my notes.
                    val targetNoteIds: Set<String> =
                        noteEvents.filter { it.pubkey == owner }.map { it.id }.toSet()

                    // Blocked zappers are hidden here; the block observer in
                    // init{} reruns this pass, so unblocking brings them back.
                    val received = VaultZapsReceived.build(
                        receipts = parsedReceipts.map {
                            VaultZapsReceived.Receipt(it.parsed, receiptTimes[it.receiptId] ?: 0L)
                        },
                        myNoteIds = targetNoteIds,
                        owner = owner,
                        isBlocked = { it in blocked },
                    )
                    val zMap = received.zappers
                    val lastZapAt = received.lastZapAt

                    val zappedNoteIds = zMap.keys
                    val filtered = RelayGiven.newestZapFirst(
                        noteEvents.filter { zappedNoteIds.contains(it.id) },
                        lastZapAt,
                        { it.id },
                        { it.createdAt },
                    )

                    val displaySlice = filtered.take(maxDisplayedItems).map { event ->
                        FeedNote.fromEvent(event.id, event.pubkey, event.content, event.tags, event.createdAt, event.kind)
                    }

                    if (gen != updateGeneration) return@withContext
                    withContext(Dispatchers.Main.immediate) {
                        _displayZappedNotes.value = displaySlice
                        _zapMap.value = zMap
                        if (displaySlice.isNotEmpty()) _zapsHasLoadedOnce.value = true
                    }
                }
            }
        }
    }

    // ── External relay fetching (port of iOS VaultNetworking) ────

/**
 * A repost is a second card for a post. When the original is listed with its
 * engagement bar (your note or a whitelisted one), the repost is already
 * counted there, so its card goes; several reposts of a note that isn't
 * listed collapse to the newest. [events] must be newest first.
 * iOS updateDisplayData (VaultDataProcessing.swift).
 */
internal object VaultRepostDedupe {
    fun apply(events: List<NostrEvent>, owner: String, whitelist: Set<String>): List<NostrEvent> {
        val listedWithEngagement = events.asSequence()
            .filter { it.kind != 6 && (it.pubkey == owner || it.pubkey in whitelist) }
            .map { it.id }
            .toHashSet()
        val shownTargets = HashSet<String>()
        return events.filter { event ->
            if (event.kind != 6) return@filter true
            val target = event.tags.firstOrNull { it.size >= 2 && it[0] == "e" }?.get(1)
                ?: return@filter true
            target !in listedWithEngagement && shownTargets.add(target)
        }
    }
}
