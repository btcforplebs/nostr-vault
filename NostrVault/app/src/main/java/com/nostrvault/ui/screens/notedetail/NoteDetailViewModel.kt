package com.nostrvault.ui.screens

import com.nostrvault.service.liveThreadReplies
import com.nostrvault.ui.components.ZapFlight
import androidx.compose.foundation.layout.*
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.lifecycle.SavedStateHandle
import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import com.nostrvault.data.local.ConfigStore
import com.nostrvault.data.model.*
import com.nostrvault.service.FeedService
import com.nostrvault.service.FeedNoteRemoval
import com.nostrvault.service.NostrService
import com.nostrvault.service.deleteNote
import com.nostrvault.service.isDeleted
import com.nostrvault.service.PendingPostManager
import com.nostrvault.service.ZapSendService
import com.nostrvault.service.removeNote
import com.nostrvault.service.retryMissingNote
import com.nostrvault.ui.components.*
import com.nostrvault.ui.theme.*
import dagger.hilt.android.lifecycle.HiltViewModel
import kotlinx.coroutines.flow.*
import kotlinx.coroutines.launch
import kotlinx.coroutines.withTimeoutOrNull
import java.util.*
import javax.inject.Inject

/** Loading-row fallback when relays never send EOSE (iOS uses 6 s too). */
private const val LOADING_TIMEOUT_MS = 6_000L

/**
 * A response that isn't a thread row: a quote (a `q` tag on the root, and not
 * itself a reply), a highlight, a voice reply, or any other kind pointing at
 * the root. Replies, comments, reactions, reposts and zaps live elsewhere.
 * iOS: NoteDetailView.isOtherResponse.
 */
internal fun isOtherResponse(note: FeedNote, rootId: String): Boolean {
    if (note.kind in setOf(1, NIP10Thread.COMMENT_KIND, 6, 7, 9735)) {
        if (note.kind != 1) return false
        val quotesRoot = note.tags.any { it.size >= 2 && it[0] == "q" && it[1] == rootId }
        return quotesRoot && NIP10Thread.parentEventId(note.kind, note.tags) == null
    }
    return true
}

@HiltViewModel
class NoteDetailViewModel @Inject constructor(
    savedStateHandle: SavedStateHandle,
    private val nostrService: NostrService,
    private val feedService: FeedService,
    private val configStore: ConfigStore,
    private val zapSendService: ZapSendService,
    private val pendingPostManager: PendingPostManager,
    private val notificationManager: com.nostrvault.ui.notification.NotificationManager,
) : ViewModel() {

    val noteId: String = savedStateHandle["noteId"] ?: ""

    // Direct service access for BroadcastSheet (matches FeedViewModel).
    val feedServiceRef: FeedService get() = feedService
    val nostrServiceRef: NostrService get() = nostrService
    val configStoreRef: ConfigStore get() = configStore

    private val _note = MutableStateFlow<FeedNote?>(null)
    val note: StateFlow<FeedNote?> = _note.asStateFlow()

    private val _parentNotes = MutableStateFlow<List<FeedNote>>(emptyList())
    val parentNotes: StateFlow<List<FeedNote>> = _parentNotes.asStateFlow()

    /** All replies in the thread (flat list used to build the tree). */
    private val _allReplies = MutableStateFlow<List<FeedNote>>(emptyList())
    val allReplies: StateFlow<List<FeedNote>> = _allReplies.asStateFlow()

    /** Quotes, highlights and voice replies: shown under the thread, not as rows. */
    private val _otherResponses = MutableStateFlow<List<FeedNote>>(emptyList())
    val otherResponses: StateFlow<List<FeedNote>> = _otherResponses.asStateFlow()

    val profiles: StateFlow<Map<String, FeedProfile>> = nostrService.profiles
    val noteStats: StateFlow<Map<String, NoteStats>> = feedService.noteStats
    val likedEventIds: StateFlow<Set<String>> = feedService.likedEventIds
    val repostedEventIds: StateFlow<Set<String>> = feedService.repostedEventIds

    // Staged loading (iOS parity): the hero renders immediately; parents and
    // replies show inline loading states while their fetches are in flight.
    // isLoadingNote covers only the fetch-by-id fallback for uncached notes.
    private val _isLoadingNote = MutableStateFlow(false)
    val isLoadingNote: StateFlow<Boolean> = _isLoadingNote.asStateFlow()

    private val _isLoadingParents = MutableStateFlow(false)
    val isLoadingParents: StateFlow<Boolean> = _isLoadingParents.asStateFlow()

    private val _isLoadingReplies = MutableStateFlow(false)
    val isLoadingReplies: StateFlow<Boolean> = _isLoadingReplies.asStateFlow()

    private val _isRefreshing = MutableStateFlow(false)
    val isRefreshing: StateFlow<Boolean> = _isRefreshing.asStateFlow()

    // Engagement details for the focused (hero) note
    private val _engagementDetails = MutableStateFlow<EngagementDetails?>(null)
    val engagementDetails: StateFlow<EngagementDetails?> = _engagementDetails.asStateFlow()

    // Thread-wide engagement stats
    private val _expandedEngagement = MutableStateFlow(configStore.config.value.noteDetailExpandedEngagement)
    val expandedEngagement: StateFlow<Boolean> = _expandedEngagement.asStateFlow()

    // Zap state: transient user-facing messages + in-flight guard
    private val _isZapping = MutableStateFlow(false)
    val isZapping: StateFlow<Boolean> = _isZapping.asStateFlow()

    private val _perNoteEngagement = MutableStateFlow<Map<String, EngagementDetails>>(emptyMap())
    val perNoteEngagement: StateFlow<Map<String, EngagementDetails>> = _perNoteEngagement.asStateFlow()

    /** The active account's blocked people (hex), kept current so blocking from here hides them at once. */
    val blockedPubkeys: StateFlow<Set<String>> = configStore.config
        .map { feedService.blockedHexForActiveAccount() }
        .stateIn(viewModelScope, SharingStarted.Eagerly, feedService.blockedHexForActiveAccount())

    val activeHexPubkey: String get() = nostrService.activeHexPubkey

    init {
        loadNoteThread()
        // Optimistic reply insertion: when the user publishes a reply from
        // ComposeNoteScreen it is emitted here immediately, before relay
        // confirmation, so it appears inline without waiting for a round-trip.
        viewModelScope.launch {
            feedService.optimisticNote.collect { note ->
                mergeReplies(listOf(note))
            }
        }
        // ...and taken out again when the countdown banner's Cancel or Edit
        // stops it, so no reply that was never sent stays in the thread.
        viewModelScope.launch {
            pendingPostManager.withdrawn.collect(::removeReply)
        }
    }

    private fun loadNoteThread() {
        val cached = feedService.findNote(noteId)
        if (cached != null && cached.kind == 6) {
            openRepostedOriginal(cached)
            return
        }
        if (cached != null) {
            startThreadLoad(cached)
            return
        }
        // Not in the in-memory feed cache (opened from an engagement sheet,
        // old screen, etc.) — fall back to fetching the note itself by id
        // from the relays before declaring it not found (iOS wrapper parity).
        _isLoadingNote.value = true
        nostrService.fetchNoteById(noteId, onRawEvent = feedService::cacheRawEvent) { fetched ->
            if (fetched != null) {
                _isLoadingNote.value = false
                startThreadLoad(fetched)
            } else {
                lookUpOnMiss()
            }
        }
    }

    /**
     * Not on your relays: hand the id to the feed's lookup, which asks the
     * author's relays and then the last-stop relays (FALLBACK_NOTE_RELAYS),
     * and wait for it to land or be given up on. iOS NoteDetailViewWrapper.
     * A user opening the note is a fresh ask, so an earlier give-up is forgotten.
     */
    private fun lookUpOnMiss() {
        if (noteId.length != 64) { _isLoadingNote.value = false; return }
        feedService.retryMissingNote(noteId)
        viewModelScope.launch {
            // (the note, or null once the lookup has given up on it)
            val outcome = withTimeoutOrNull(20_000L) {
                combine(feedService.parentNotesCache, feedService.unavailableNoteIds) { cache, unavailable ->
                    cache[noteId] to (noteId in unavailable)
                }.first { (note, givenUp) -> note != null || givenUp }
            }
            _isLoadingNote.value = false
            outcome?.first?.let { startThreadLoad(it) }
        }
    }

    /**
     * A repost opens the note it reposted (iOS #326): the thread, likes, zaps,
     * author and menu all belong to the original. A bare repost whose original
     * isn't loaded fetches it by id, and keeps the repost if no relay has it.
     */
    private fun openRepostedOriginal(repost: FeedNote) {
        val original = feedService.quoteTarget(repost.id)
        if (original == null || original.id == repost.id) {
            startThreadLoad(repost)
            return
        }
        if (original.content.isNotEmpty()) {
            startThreadLoad(original)
            return
        }
        _isLoadingNote.value = true
        nostrService.fetchNoteById(original.id, onRawEvent = feedService::cacheRawEvent) { fetched ->
            _isLoadingNote.value = false
            startThreadLoad(fetched ?: repost)
        }
    }

    /**
     * Kick off the thread + engagement fetches around [foundNote]. Safe to
     * call again for pull-to-refresh: merges are idempotent and existing
     * state is never nulled. [showLoadingStates] drives the inline loading
     * rows; refresh keeps the current content visible instead.
     */
    private fun startThreadLoad(foundNote: FeedNote, showLoadingStates: Boolean = true) {
        _note.value = foundNote
        feedService.cacheNote(foundNote)

        // Add the opened note into the reply pool immediately so it shows up as
        // a child when its parent is focused. Without this, legacy notes that
        // only tag their direct parent (not the thread root) are never returned
        // by the #e:[rootId] relay query, so focusing the parent shows "No replies".
        mergeReplies(listOf(foundNote))

        // Initial ancestor chain from the in-memory cache.
        val cachedChain = buildAncestorChain(foundNote, _allReplies.value)
        _parentNotes.value = cachedChain

        if (showLoadingStates) {
            // Parents reveal atomically (iOS parity) — unless the cached
            // chain already reaches a top-level note, in which case it is
            // complete and can show immediately.
            val chainComplete = foundNote.parentEventId == null ||
                (cachedChain.isNotEmpty() && cachedChain.first().parentEventId == null)
            _isLoadingParents.value = !chainComplete
            _isLoadingReplies.value = true
        }

        // Fetch the whole thread by NIP-10 root so a mid-thread reply opens
        // with its siblings + ancestors (matching iOS), not just the opened
        // note's direct replies. Ancestor e-tags (minus mentions) are
        // fetched by id to fill any gaps in the chain. For kind-6 reposts
        // both root and focus redirect to the reposted (inner) event so the
        // original's replies are actually found.
        val effectiveId = foundNote.effectiveEventId
        val rootId = foundNote.threadRootId
        val ancestorIds = foundNote.tags
            .filter { it.size >= 2 && it[0] == "e" && (it.size < 4 || it[3] != "mention") }
            .map { it[1] }
        // The root's address when it's addressable or replaceable (or the
        // A a comment carries), so comments on an edited article still load.
        val rootCoordinate = if (foundNote.kind == NIP10Thread.COMMENT_KIND) {
            foundNote.tags.firstOrNull { it.size >= 2 && it[0] == "A" }?.get(1)
        } else if (rootId == foundNote.id) {
            NIP10Thread.coordinate(foundNote.kind, foundNote.pubkey, foundNote.tags)
        } else null
        nostrService.fetchOtherResponses(rootId, rootCoordinate) { found ->
            _otherResponses.value = found
                .filter { isOtherResponse(it, rootId) && !FeedNote.isNoiseOrSpam(it.content, it.tags) && !feedService.isDeleted(it.id) }
                .sortedByDescending { it.createdAt }
            nostrService.fetchMissingProfiles(found.map { it.pubkey }.distinct())
        }
        nostrService.fetchThread(rootId, effectiveId, ancestorIds, rootCoordinate, onRawEvent = feedService::cacheRawEvent) { threadNotes ->
            mergeReplies(threadNotes)
            // Rebuild the chain now that fetched notes may fill gaps.
            _parentNotes.value = buildAncestorChain(foundNote, _allReplies.value)
            _isLoadingParents.value = false
            _isLoadingReplies.value = false
            _isRefreshing.value = false
            fetchMissingThreadProfiles(foundNote)
            if (_expandedEngagement.value && _perNoteEngagement.value.isEmpty()) {
                fetchThreadEngagement()
            }
        }
        // New replies stream in while the thread is open (iOS keeps its REQ
        // open past EOSE); a refresh or a new note replaces the subscription.
        startLiveReplies(rootId, effectiveId, rootCoordinate)
        // Relays that never EOSE must not leave the loading rows up forever.
        viewModelScope.launch {
            kotlinx.coroutines.delay(LOADING_TIMEOUT_MS)
            _isLoadingParents.value = false
            _isLoadingReplies.value = false
            _isRefreshing.value = false
        }

        fetchMissingThreadProfiles(foundNote)
        fetchEngagement(effectiveId)
    }

    private var liveReplies: kotlinx.coroutines.Job? = null

    /** Replies arriving after the thread opened: merged in as they land, their authors' profiles fetched. */
    private fun startLiveReplies(rootId: String, focusedId: String, rootCoordinate: String?) {
        liveReplies?.cancel()
        liveReplies = viewModelScope.launch {
            nostrService.liveThreadReplies(rootId, focusedId, rootCoordinate).collect { (reply, raw) ->
                feedService.cacheRawEvent(reply.id, raw)
                mergeReplies(listOf(reply))
                if (nostrService.profiles.value[reply.pubkey] == null) nostrService.fetchMissingProfiles(listOf(reply.pubkey))
            }
        }
    }

    private fun fetchMissingThreadProfiles(foundNote: FeedNote) {
        val pubkeys = buildList {
            addAll(_parentNotes.value.map { it.pubkey })
            add(foundNote.pubkey)
            addAll(_allReplies.value.map { it.pubkey })
        }.distinct()
        nostrService.fetchMissingProfiles(pubkeys)
    }

    /** Idempotent merge — fetch callbacks fire once per relay EOSE. */
    private fun removeReply(id: String) {
        _allReplies.update { replies -> replies.filterNot { it.id == id } }
    }

    private fun mergeReplies(fetched: List<FeedNote>) {
        // A deleted post never comes back as a parent or a reply.
        val incoming = fetched.filterNot { feedService.isDeleted(it.id) }
        if (incoming.isEmpty()) return
        _allReplies.value = (_allReplies.value + incoming)
            .distinctBy { it.id }
            .sortedBy { it.createdAt }
        incoming.forEach { feedService.cacheNote(it) }
    }

    /**
     * Pull in replies that tag only the newly focused note (legacy clients
     * skip the root tag); called when the thread view refocuses. Also
     * queries the note's known children so nested legacy chains resolve a
     * level deeper. Shows the replies-loading row while nothing is known
     * yet, and fetches profiles for newly discovered repliers.
     */
    fun fetchRepliesForFocus(targetId: String) {
        val knownChildIds = _allReplies.value
            .filter { it.parentEventId == targetId }
            .map { it.id }
        if (knownChildIds.isEmpty()) _isLoadingReplies.value = true
        nostrService.fetchRepliesFor(
            listOf(targetId) + knownChildIds,
            onRawEvent = feedService::cacheRawEvent,
        ) { notes ->
            mergeReplies(notes)
            _isLoadingReplies.value = false
            nostrService.fetchMissingProfiles(notes.map { it.pubkey }.distinct())
        }
        viewModelScope.launch {
            kotlinx.coroutines.delay(LOADING_TIMEOUT_MS)
            _isLoadingReplies.value = false
        }
    }

    /** Pull-to-refresh: re-run the thread fetch without nulling state. */
    fun refresh() {
        val current = _note.value ?: return
        if (_isRefreshing.value) return
        _isRefreshing.value = true
        startThreadLoad(current, showLoadingStates = false)
    }

    /**
     * Walk parentEventId upward, resolving each ancestor from the in-memory
     * cache first, then from [extra] (e.g. notes just fetched from the
     * network). Cycle-guarded; returns the chain oldest-first.
     */
    private fun buildAncestorChain(note: FeedNote, extra: List<FeedNote>): List<FeedNote> {
        val lookup = extra.associateBy { it.id }
        val chain = mutableListOf<FeedNote>()
        val seen = HashSet<String>()
        var currentId = note.parentEventId
        while (currentId != null && seen.add(currentId)) {
            val parent = feedService.findNote(currentId) ?: lookup[currentId]
            if (parent != null) {
                chain.add(0, parent)
                currentId = parent.parentEventId
            } else {
                break
            }
        }
        return chain
    }

    fun fetchEngagement(noteId: String) {
        feedService.fetchEngagementDetails(noteId) { details ->
            _engagementDetails.value = details
        }
    }

    /**
     * Real NIP-57 zap of [note] (effective id handles kind-6 reposts).
     * The zap pill reports the result (docs/pills.md); engagement re-fetches
     * after a delay so the kind-9735 receipt has time to propagate (iOS parity).
     */
    fun zapNote(note: FeedNote, amountSats: Int) {
        if (_isZapping.value) return
        viewModelScope.launch {
            _isZapping.value = true
            val result = notificationManager.zapping(
                com.nostrvault.ui.screens.feed.zapRecipientName(profiles.value, note.effectiveAuthor),
                amountSats,
            ) { zapSendService.zapNote(note.effectiveEventId, note.effectiveAuthor, amountSats) }
            _isZapping.value = false
            result.onSuccess {
                ZapFlight.launch(note.effectiveEventId)
                kotlinx.coroutines.delay(3_000)
                fetchEngagement(note.effectiveEventId)
            }
        }
    }

    fun likeNote(noteId: String) {
        viewModelScope.launch { feedService.likeNote(noteId) }
    }

    fun reactToNote(noteId: String, emoji: String) {
        viewModelScope.launch { feedService.likeNote(noteId, emoji) }
    }

    /** After the send-delay countdown, so the banner can undo it. */
    fun repostNote(noteId: String) = pendingPostManager.startRepost(noteId, feedService)

    // Moderation
    fun isOwnNote(pubkey: String): Boolean = pubkey == nostrService.activeHexPubkey

    /** The avatar quick menu: Follow/Unfollow and Block (iOS FeedView avatar toolbar). */
    val avatarMenu = com.nostrvault.ui.components.avatarMenuActions(feedService, ::isOwnNote)

    fun followUser(pubkey: String) {
        viewModelScope.launch { feedService.followUser(pubkey) }
    }

    fun unfollowUser(pubkey: String) {
        viewModelScope.launch { feedService.unfollowUser(pubkey) }
    }

    fun isFollowing(pubkey: String): Boolean = feedService.isFollowing(pubkey)

    fun blockUser(pubkey: String) {
        viewModelScope.launch { feedService.blockUser(pubkey) }
    }

    /**
     * After the send-delay countdown, so the banner can undo it. Deleting a
     * parent or a reply takes it off this screen too, when it goes out; the
     * focused note closes the screen.
     */
    fun deleteNote(noteId: String) = pendingPostManager.startDelete(noteId, nostrService, feedService) {
        _parentNotes.value = FeedNoteRemoval.without(_parentNotes.value, noteId)
        _allReplies.value = FeedNoteRemoval.without(_allReplies.value, noteId)
        _otherResponses.value = FeedNoteRemoval.without(_otherResponses.value, noteId)
    }

    fun reportNote(noteId: String, pubkey: String, reason: String, description: String = "") {
        viewModelScope.launch {
            nostrService.reportEvent(noteId, pubkey, reason, description.ifBlank { null })
            // iOS UGCReportingDialog also blocks the reported user.
            feedService.blockUser(pubkey)
        }
    }

    // Thread-wide stats
    fun toggleExpandedEngagement() {
        _expandedEngagement.value = !_expandedEngagement.value
        configStore.update { it.copy(noteDetailExpandedEngagement = _expandedEngagement.value) }
        if (_expandedEngagement.value && _perNoteEngagement.value.isEmpty()) {
            fetchThreadEngagement()
        }
    }

    private fun fetchThreadEngagement() {
        val allIds = buildList {
            addAll(_parentNotes.value.map { it.id })
            _note.value?.id?.let { add(it) }
            addAll(_allReplies.value.map { it.id })
        }
        if (allIds.isEmpty()) return
        feedService.fetchThreadEngagement(allIds) { result ->
            _perNoteEngagement.value = result
        }
    }

    /**
     * The people in one thread note's engagement, for its sheet. The thread
     * batch fetch does not load them (the focused note's own fetch does), so
     * this runs once when a sheet opens rather than for every row.
     */
    fun fetchEngagementProfiles(details: EngagementDetails) {
        val pubkeys = buildList {
            details.reactions.mapTo(this) { it.pubkey }
            details.zaps.mapTo(this) { it.zapperPubkey }
            details.reposts.mapTo(this) { it.pubkey }
        }.distinct()
        if (pubkeys.isNotEmpty()) nostrService.fetchMissingProfiles(pubkeys)
    }

    fun profileFor(pubkey: String): FeedProfile? = profiles.value[pubkey]
    fun statsFor(noteId: String): NoteStats? = noteStats.value[noteId]
    fun isLiked(noteId: String): Boolean = likedEventIds.value.contains(noteId)
    fun isReposted(noteId: String): Boolean = repostedEventIds.value.contains(noteId)

    /** A note this thread or the feed has loaded: what a bare repost line carries. */
    fun findNote(id: String): FeedNote? =
        feedService.findNote(id) ?: _allReplies.value.firstOrNull { it.id == id }

    // ── Quoted note resolution (embedded nostr:note1/nevent1 previews) ──

    val quotedNotesCache: StateFlow<Map<String, FeedNote>> = feedService.quotedNotes

    fun quotedNoteFor(identifier: String): FeedNote? = feedService.quotedNoteFor(identifier)

    fun fetchMissingQuotedNotes(identifiers: List<String>) =
        feedService.fetchMissingQuotedNotes(identifiers)

    fun fetchMissingQuotedProfiles(identifiers: List<String>) =
        feedService.fetchMissingQuotedProfiles(identifiers)
}
