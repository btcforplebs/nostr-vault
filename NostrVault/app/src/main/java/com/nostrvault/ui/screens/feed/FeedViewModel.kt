package com.nostrvault.ui.screens.feed

import androidx.compose.runtime.mutableStateMapOf
import androidx.compose.runtime.snapshots.SnapshotStateMap
import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import com.nostrvault.data.local.ConfigStore
import com.nostrvault.data.model.FeedLayoutMode
import com.nostrvault.data.model.FeedMode
import com.nostrvault.data.model.FeedNote
import com.nostrvault.data.model.FeedProfile
import com.nostrvault.data.model.MediaFeedMode
import com.nostrvault.data.model.NoteStats
import com.nostrvault.data.model.FeedThread
import com.nostrvault.data.model.FeedThreadGrouping
import com.nostrvault.data.model.PopularFilter
import com.nostrvault.service.LiveFeedService
import com.nostrvault.service.FeedService
import com.nostrvault.service.NostrService
import com.nostrvault.service.ScrollPosition
import com.nostrvault.service.ZapSendService
import com.nostrvault.ui.notification.NotificationManager
import dagger.hilt.android.lifecycle.HiltViewModel
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.FlowPreview
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.*
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import javax.inject.Inject

/**
 * ViewModel for the main feed screen.
 * Bridges FeedService + NostrService state into composable-friendly flows.
 */
@OptIn(FlowPreview::class)
@HiltViewModel
class FeedViewModel @Inject constructor(
    private val feedService: FeedService,
    private val nostrService: NostrService,
    private val configStore: ConfigStore,
    private val notificationManager: NotificationManager,
    private val zapSendService: ZapSendService,
    private val liveFeedService: LiveFeedService,
) : ViewModel() {

    private companion object {
        /** Relays answer metadata in bursts; three UI passes a second is plenty. */
        const val PROFILE_SAMPLE_MS = 300L
    }

    /**
     * Live streams come from their own service rather than the note list: a
     * kind-30311 event is a replaceable announcement, and one that ended two
     * minutes ago still says "live" in anything cached, so Live always
     * refetches on entry.
     */
    val liveStreams = liveFeedService.streams
    val liveLoading = liveFeedService.isLoading

    fun refreshLive() = liveFeedService.refresh()

    fun liveStream(address: String) = liveFeedService.streams.value.firstOrNull { it.address == address }

    // Zap result feedback for the UI (toast)
    private val _zapMessage = MutableSharedFlow<String>(extraBufferCapacity = 4)
    val zapMessage: SharedFlow<String> = _zapMessage

    // ── Feed state ───────────────────────────────────────────────

    val notes: StateFlow<List<FeedNote>> = feedService.notes

    /**
     * Profiles as Compose state rather than a `StateFlow` the screen collects.
     *
     * This alone is not the win — `SnapshotStateMap` has one state record, so
     * any write invalidates every scope that read the map, exactly like a new
     * `Map` instance would. What it buys is *where* the read happens: the
     * screen no longer holds a `collectAsState` at the top of the composition,
     * so each feed row can wrap its own lookups in `derivedStateOf` and be
     * invalidated only when the profiles that row actually shows change. See
     * `FeedScreen`'s per-row `cardProfiles`.
     *
     * Still sampled, because the relay answers a metadata batch in bursts and
     * three UI passes a second is plenty for a name appearing.
     */
    val profileState: SnapshotStateMap<String, FeedProfile> =
        mutableStateMapOf<String, FeedProfile>().apply { putAll(nostrService.profiles.value) }
    val noteStats: StateFlow<Map<String, NoteStats>> = feedService.noteStats
    val likedEventIds: StateFlow<Set<String>> = feedService.likedEventIds
    val zappedEventIds: StateFlow<Map<String, Int>> = feedService.zappedEventIds
    val repostedEventIds: StateFlow<Set<String>> = feedService.repostedEventIds
    val connectionStatus: StateFlow<String> = feedService.connectionStatus
    val connectionColor: StateFlow<String> = feedService.connectionColor

    // ── Scroll-condense state (bottom bar + FAB) ────────────────
    val feedScrollingDown: StateFlow<Boolean> = feedService.feedScrollingDown

    fun setFeedScrollingDown(value: Boolean) = feedService.setFeedScrollingDown(value)

    // ── Pending notes (new posts indicator) ────────────────────
    val pendingNoteCount: StateFlow<Int> = feedService.pendingNotes
        .map { it.size }
        .stateIn(viewModelScope, SharingStarted.WhileSubscribed(5000), 0)

    fun applyPendingNotes() {
        feedService.applyPendingNotes()
    }

    init {
        // Diff the profile map off the main thread and write only what changed:
        // the cache holds up to 5,000 entries, and scanning that on the main
        // thread three times a second would cost more than the recompositions
        // this is here to avoid.
        viewModelScope.launch(Dispatchers.Default) {
            nostrService.profiles.sample(PROFILE_SAMPLE_MS).collect { snapshot ->
                val changed = snapshot.filterTo(HashMap()) { (pubkey, profile) ->
                    profileState[pubkey] != profile
                }
                // Entries only disappear when the service trims its cache.
                val dropped = if (snapshot.size < profileState.size) {
                    profileState.keys.filterTo(ArrayList()) { it !in snapshot }
                } else {
                    emptyList()
                }
                if (changed.isEmpty() && dropped.isEmpty()) return@collect
                withContext(Dispatchers.Main) {
                    profileState.putAll(changed)
                    dropped.forEach { profileState.remove(it) }
                }
            }
        }

        // Staggered startup: wait for relay to be ready before loading feed
        // to avoid OOM from relay + feed + media all starting simultaneously.
        viewModelScope.launch {
            com.nostrvault.relay.RelayForegroundService.readyForConnections.collect { ready ->
                if (ready && notes.value.isEmpty()) {
                    feedService.startInitialLoad()
                    return@collect
                }
            }
        }
    }

    private val _feedMode = MutableStateFlow(
        configStore.config.value.defaultFeedMode
            .let { name -> FeedMode.entries.find { it.name == name } }
            ?: FeedMode.FOLLOWING
    )
    val feedMode: StateFlow<FeedMode> = _feedMode.asStateFlow()

    private val _isRefreshing = MutableStateFlow(false)
    val isRefreshing: StateFlow<Boolean> = _isRefreshing.asStateFlow()

    private val _isLoadingMore = MutableStateFlow(false)
    val isLoadingMore: StateFlow<Boolean> = _isLoadingMore.asStateFlow()

    // ── Filtered notes ───────────────────────────────────────────
    // Use FeedService.filteredNotes which is already filtered by FeedFilterEngine
    // (handles follow list, WoT, blocked users, mode-specific rules, reply stripping)

    val filteredNotes: StateFlow<List<FeedNote>> = feedService.filteredNotes

    // Media-only notes for the grid (FeedMode.MEDIA). Already filtered by
    // FeedFilterEngine.filterMediaNotes (media-bearing, blocked/WoT/throttle rules).
    val mediaNotes: StateFlow<List<FeedNote>> = feedService.filteredMediaNotes

    // ── Feed layout mode (expanded / condensed / threaded) ──────────

    private val _layoutModeToggle = MutableStateFlow(0) // bump to trigger recomputation

    /**
     * Threading only makes sense on a timeline of notes; a media grid or an
     * article list has no replies to gather. Mirrors iOS
     * `FeedView.currentFeedSupportsThreading`.
     */
    private fun feedSupportsThreading(mode: FeedMode): Boolean = when (mode) {
        FeedMode.FOLLOWING, FeedMode.DISCOVERY, FeedMode.GLOBAL, FeedMode.POPULAR -> true
        FeedMode.MEDIA, FeedMode.ARTICLES, FeedMode.RECIPES, FeedMode.LIVE -> false
    }

    private fun defaultCompact(mode: FeedMode): Boolean = when (mode) {
        FeedMode.FOLLOWING -> false
        FeedMode.MEDIA -> false
        else -> configStore.config.value.useFeedCompactMode
    }

    /**
     * The stored layout for the current feed, migrating anyone who had the
     * old per-feed compact boolean set. Mirrors iOS
     * `FeedView.layoutModeForCurrentFeed`.
     */
    val layoutMode: StateFlow<FeedLayoutMode> = combine(
        _feedMode,
        _layoutModeToggle,
        configStore.config,
    ) { mode, _, config ->
        FeedLayoutMode.resolve(
            storedLayout = config.feedLayoutModes[mode.name],
            storedCompact = config.feedCompactModes[mode.name],
            defaultCompact = defaultCompact(mode),
        ).clamped(supportsThreading = feedSupportsThreading(mode))
    }.stateIn(viewModelScope, SharingStarted.WhileSubscribed(5000), FeedLayoutMode.EXPANDED)

    /** Condensed rows are active — either of the two condensed layouts. */
    val compactModeEnabled: StateFlow<Boolean> = layoutMode
        .map { it.usesCondensedRows }
        .stateIn(viewModelScope, SharingStarted.WhileSubscribed(5000), false)

    /** Whole conversations instead of loose rows. */
    val threadedModeEnabled: StateFlow<Boolean> = layoutMode
        .map { it == FeedLayoutMode.THREADED }
        .stateIn(viewModelScope, SharingStarted.WhileSubscribed(5000), false)

    /** Advance the current feed one step around expanded -> condensed -> threaded and persist it. */
    fun cycleLayoutMode() {
        val mode = _feedMode.value
        setLayoutMode(layoutMode.value.next(supportsThreading = feedSupportsThreading(mode)))
    }

    /** Jump straight to a layout (used by an overflow menu, where every choice is visible at once). */
    fun setLayoutMode(mode: FeedLayoutMode) {
        val feedMode = _feedMode.value
        val resolved = mode.clamped(supportsThreading = feedSupportsThreading(feedMode))
        configStore.update { config ->
            config.copy(
                feedLayoutModes = config.feedLayoutModes + (feedMode.name to resolved.storageKey),
                // Keep the legacy key in step so a downgrade still lands somewhere sane.
                feedCompactModes = config.feedCompactModes + (feedMode.name to resolved.usesCondensedRows),
            )
        }
        // A threaded feed with replies filtered out would show nothing but
        // roots, which is the layout the user just left. Turn replies on with
        // it; the Replies filter still switches them back off.
        if (resolved == FeedLayoutMode.THREADED && !feedService.showReplies.value) {
            feedService.setShowReplies(true)
        }
        _layoutModeToggle.value++
    }

    /**
     * The current feed's notes grouped into conversations. Empty outside
     * threaded mode. Mirrors iOS `FeedView.feedThreads`.
     */
    val feedThreads: StateFlow<List<FeedThread>> = combine(
        filteredNotes,
        threadedModeEnabled,
    ) { notes, threaded ->
        if (!threaded) emptyList() else FeedThreadGrouping.build(notes) { id -> feedService.findNote(id) }
    }.stateIn(viewModelScope, SharingStarted.WhileSubscribed(5000), emptyList())

    fun fetchMissingNote(id: String) = feedService.fetchMissingNote(id)

    // ── Feed filter toggles (per-mode) ─────────────────────────

    private val _autoLoadEnabled = MutableStateFlow(true)
    val autoLoadEnabled: StateFlow<Boolean> = _autoLoadEnabled.asStateFlow()

    val showReposts: StateFlow<Boolean> = feedService.showReposts

    val showReplies: StateFlow<Boolean> = feedService.showReplies

    // Derived from FeedService's media sub-mode so the toggle reflects (and drives)
    // the actual subscription/filter scope rather than a disconnected local flag.
    val mediaFollowingOnly: StateFlow<Boolean> = feedService.mediaFeedMode
        .map { it == MediaFeedMode.FOLLOWING }
        .stateIn(viewModelScope, SharingStarted.WhileSubscribed(5000), true)

    val popularFilter: StateFlow<PopularFilter> = feedService.popularFilter

    private val _showEngagementStats = MutableStateFlow(false)
    val showEngagementStats: StateFlow<Boolean> = _showEngagementStats.asStateFlow()

    fun toggleAutoLoad() { _autoLoadEnabled.value = !_autoLoadEnabled.value }
    fun toggleShowReposts() { feedService.setShowReposts(!showReposts.value) }
    fun toggleShowReplies() { feedService.setShowReplies(!showReplies.value) }
    fun toggleMediaFollowing() {
        feedService.setMediaFeedMode(
            if (mediaFollowingOnly.value) MediaFeedMode.GLOBAL else MediaFeedMode.FOLLOWING
        )
    }
    fun toggleShowEngagementStats() { _showEngagementStats.value = !_showEngagementStats.value }
    fun setPopularFilter(filter: PopularFilter) { feedService.setPopularFilter(filter) }

    // ── Actions ──────────────────────────────────────────────────

    fun setFeedMode(mode: FeedMode) {
        _feedMode.value = mode
        if (mode == FeedMode.LIVE) {
            // Nothing to switch on the note subscription — Live has its own.
            liveFeedService.refresh()
            return
        }
        viewModelScope.launch {
            feedService.switchFeedMode(mode)
        }
    }

    fun refresh() {
        // Ask the embedded relay to catch up its inbox/outbox from external
        // relays too, so a feed pull-to-refresh also freshens the Dashboard,
        // DMs, and notifications. Non-blocking, coalesced in Go, safe when the
        // relay isn't running.
        runCatching { com.nostrvault.relay.HavenBridge.requestRelaySync() }
        viewModelScope.launch {
            _isRefreshing.value = true
            feedService.refresh()
            _isRefreshing.value = false
        }
    }

    fun loadMore() {
        if (_isLoadingMore.value) return
        viewModelScope.launch {
            _isLoadingMore.value = true
            feedService.loadOlderNotes()
            _isLoadingMore.value = false
        }
    }

    fun likeNote(noteId: String, emoji: String? = null) {
        if (likedEventIds.value.contains(noteId) && emoji == null) {
            // Already liked — start unlike countdown
            notificationManager.startUnlikeCountdown {
                feedService.unlikeNote(noteId)
            }
            return
        }
        viewModelScope.launch {
            feedService.likeNote(noteId, emoji)
        }
    }

    fun repostNote(noteId: String) {
        viewModelScope.launch {
            feedService.repostNote(noteId)
        }
    }

    fun zapNote(noteId: String, amount: Int = 21) {
        viewModelScope.launch {
            val note = feedService.findNote(noteId)
            if (note == null) {
                _zapMessage.emit("Note not found")
                return@launch
            }
            // Real NIP-57 zap; effective id redirects kind-6 reposts to the
            // reposted event. ZapSendService bumps local stats on success.
            zapSendService.zapNote(note.effectiveEventId, note.pubkey, amount).fold(
                onSuccess = { _zapMessage.emit("Zapped ⚡$amount sats") },
                onFailure = { e -> _zapMessage.emit(e.message ?: "Zap failed") },
            )
        }
    }

    fun deleteNote(noteId: String) {
        viewModelScope.launch {
            nostrService.deleteNote(noteId)
            feedService.removeNote(noteId)
        }
    }

    fun isOwnNote(pubkey: String): Boolean {
        return pubkey == nostrService.activeHexPubkey
    }

    // ── Moderation ─────────────────────────────────────────────
    //
    // Same paths NoteDetailScreen already uses. Blocking writes the npub to
    // `blockedNpubs`, publishes the mute list, and drops the author's notes from
    // the in-memory feed — which is why the feed visibly loses them without a
    // reload. Block and mute are one action in this app; the menu says "Block"
    // once rather than offering two labels for the same event.

    fun blockUser(pubkey: String) {
        viewModelScope.launch { feedService.blockUser(pubkey) }
    }

    /** NIP-56 report. Also blocks the author, matching NoteDetail and iOS. */
    fun reportNote(noteId: String, pubkey: String, reason: String, description: String = "") {
        viewModelScope.launch {
            nostrService.reportEvent(noteId, pubkey, reason, description.ifBlank { null })
            feedService.blockUser(pubkey)
        }
    }

    // Exposed for BroadcastSheet which needs direct service access
    val feedServiceRef: FeedService get() = feedService
    val nostrServiceRef: NostrService get() = nostrService
    val configStoreRef: ConfigStore get() = configStore

    // ── Scroll position persistence ────────────────────────────

    val restoredScrollPosition: StateFlow<ScrollPosition?> = feedService.restoredScrollPosition
    val scrollToTopRequest = feedService.scrollToTopRequest

    fun saveScrollPosition(index: Int, offset: Int) {
        feedService.updateScrollPosition(index, offset)
    }

    fun clearRestoredPosition() {
        feedService.clearRestoredScrollPosition()
    }

    // ── Parent note cache (for inline reply previews) ──────────

    val parentNotesCache: StateFlow<Map<String, FeedNote>> = feedService.parentNotesCache

    /** Fetched quoted events, keyed by the lookup key `quotedEventIds` holds. */
    val quotedNotesCache: StateFlow<Map<String, FeedNote>> = feedService.quotedNotes
    val parentIsNextNote: StateFlow<Set<String>> = feedService.parentIsNextNote

    fun parentNoteFor(eventId: String): FeedNote? = parentNotesCache.value[eventId]

    fun isParentNext(noteId: String): Boolean = parentIsNextNote.value.contains(noteId)

    fun fetchMissingParentNote(parentEventId: String) {
        feedService.fetchMissingNote(parentEventId)
    }

    fun fetchMissingParentNotes(parentEventIds: List<String>) {
        feedService.fetchMissingNotesBatch(parentEventIds)
    }

    // ── Quoted note cache (for embedded nostr:note1/nevent1 previews) ──

    fun quotedNoteFor(identifier: String): FeedNote? = feedService.quotedNoteFor(identifier)

    fun fetchMissingQuotedNotes(identifiers: List<String>) =
        feedService.fetchMissingQuotedNotes(identifiers)

    fun fetchMissingQuotedProfiles(identifiers: List<String>) =
        feedService.fetchMissingQuotedProfiles(identifiers)

    // ── Helpers ──────────────────────────────────────────────────

    // Read the live (un-sampled) map so per-note keyed lookups are never stale.
    fun profileFor(pubkey: String): FeedProfile? = nostrService.profiles.value[pubkey]
    fun statsFor(noteId: String): NoteStats? = noteStats.value[noteId]
    fun isLiked(noteId: String): Boolean = likedEventIds.value.contains(noteId)
    fun isZapped(noteId: String): Boolean = zappedEventIds.value.contains(noteId)
    fun isReposted(noteId: String): Boolean = repostedEventIds.value.contains(noteId)
}
