package com.nostrvault.ui.screens.feed

import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import com.nostrvault.data.local.ConfigStore
import com.nostrvault.data.model.FeedMode
import com.nostrvault.data.model.FeedNote
import com.nostrvault.data.model.FeedProfile
import com.nostrvault.data.model.NoteStats
import com.nostrvault.data.model.PopularFilter
import com.nostrvault.service.FeedService
import com.nostrvault.service.NostrService
import com.nostrvault.service.ScrollPosition
import com.nostrvault.service.ZapSendService
import com.nostrvault.ui.notification.NotificationManager
import dagger.hilt.android.lifecycle.HiltViewModel
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.*
import kotlinx.coroutines.launch
import javax.inject.Inject

/**
 * ViewModel for the main feed screen.
 * Bridges FeedService + NostrService state into composable-friendly flows.
 */
@HiltViewModel
class FeedViewModel @Inject constructor(
    private val feedService: FeedService,
    private val nostrService: NostrService,
    private val configStore: ConfigStore,
    private val notificationManager: NotificationManager,
    private val zapSendService: ZapSendService,
) : ViewModel() {

    // Zap result feedback for the UI (toast)
    private val _zapMessage = MutableSharedFlow<String>(extraBufferCapacity = 4)
    val zapMessage: SharedFlow<String> = _zapMessage

    // ── Feed state ───────────────────────────────────────────────

    val notes: StateFlow<List<FeedNote>> = feedService.notes
    val profiles: StateFlow<Map<String, FeedProfile>> = nostrService.profiles
    val noteStats: StateFlow<Map<String, NoteStats>> = feedService.noteStats
    val likedEventIds: StateFlow<Set<String>> = feedService.likedEventIds
    val zappedEventIds: StateFlow<Map<String, Int>> = feedService.zappedEventIds
    val connectionStatus: StateFlow<String> = feedService.connectionStatus
    val connectionColor: StateFlow<String> = feedService.connectionColor

    // ── Pending notes (new posts indicator) ────────────────────
    val pendingNoteCount: StateFlow<Int> = feedService.pendingNotes
        .map { it.size }
        .stateIn(viewModelScope, SharingStarted.WhileSubscribed(5000), 0)

    fun applyPendingNotes() {
        feedService.applyPendingNotes()
    }

    init {
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

    // ── Compact mode ──────────────────────────────────────────────

    private val _compactModeToggle = MutableStateFlow(0) // bump to trigger recomputation

    val compactModeEnabled: StateFlow<Boolean> = combine(
        _feedMode,
        _compactModeToggle,
        configStore.config,
    ) { mode, _, config ->
        val perFeedOverride = config.feedCompactModes[mode.name]
        if (perFeedOverride != null) return@combine perFeedOverride
        when (mode) {
            FeedMode.FOLLOWING -> false
            FeedMode.MEDIA -> false
            else -> config.useFeedCompactMode
        }
    }.stateIn(viewModelScope, SharingStarted.WhileSubscribed(5000), false)

    fun toggleCompactMode() {
        val mode = _feedMode.value
        val current = compactModeEnabled.value
        configStore.update { config ->
            config.copy(
                feedCompactModes = config.feedCompactModes + (mode.name to !current)
            )
        }
        _compactModeToggle.value++
    }

    // ── Feed filter toggles (per-mode) ─────────────────────────

    private val _autoLoadEnabled = MutableStateFlow(true)
    val autoLoadEnabled: StateFlow<Boolean> = _autoLoadEnabled.asStateFlow()

    val showReposts: StateFlow<Boolean> = feedService.showReposts

    val showReplies: StateFlow<Boolean> = feedService.showReplies

    private val _mediaFollowingOnly = MutableStateFlow(true)
    val mediaFollowingOnly: StateFlow<Boolean> = _mediaFollowingOnly.asStateFlow()

    val popularFilter: StateFlow<PopularFilter> = feedService.popularFilter

    private val _showEngagementStats = MutableStateFlow(false)
    val showEngagementStats: StateFlow<Boolean> = _showEngagementStats.asStateFlow()

    fun toggleAutoLoad() { _autoLoadEnabled.value = !_autoLoadEnabled.value }
    fun toggleShowReposts() { feedService.setShowReposts(!showReposts.value) }
    fun toggleShowReplies() { feedService.setShowReplies(!showReplies.value) }
    fun toggleMediaFollowing() { _mediaFollowingOnly.value = !_mediaFollowingOnly.value }
    fun toggleShowEngagementStats() { _showEngagementStats.value = !_showEngagementStats.value }
    fun setPopularFilter(filter: PopularFilter) { feedService.setPopularFilter(filter) }

    // ── Actions ──────────────────────────────────────────────────

    fun setFeedMode(mode: FeedMode) {
        _feedMode.value = mode
        viewModelScope.launch {
            feedService.switchFeedMode(mode)
        }
    }

    fun refresh() {
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
    val parentIsNextNote: StateFlow<Set<String>> = feedService.parentIsNextNote

    fun parentNoteFor(eventId: String): FeedNote? = parentNotesCache.value[eventId]

    fun isParentNext(noteId: String): Boolean = parentIsNextNote.value.contains(noteId)

    fun fetchMissingParentNote(parentEventId: String) {
        feedService.fetchMissingNote(parentEventId)
    }

    fun fetchMissingParentNotes(parentEventIds: List<String>) {
        feedService.fetchMissingNotesBatch(parentEventIds)
    }

    // ── Helpers ──────────────────────────────────────────────────

    fun profileFor(pubkey: String): FeedProfile? = profiles.value[pubkey]
    fun statsFor(noteId: String): NoteStats? = noteStats.value[noteId]
    fun isLiked(noteId: String): Boolean = likedEventIds.value.contains(noteId)
    fun isZapped(noteId: String): Boolean = zappedEventIds.value.contains(noteId)
}
