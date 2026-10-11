package com.nostrvault.ui.screens

import com.nostrvault.ui.components.ZapFlight
import androidx.compose.foundation.layout.*
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import com.nostrvault.data.local.ConfigStore
import com.nostrvault.data.model.FeedNote
import com.nostrvault.data.model.FeedProfile
import com.nostrvault.data.model.GlobalSearchResults
import com.nostrvault.data.model.SearchSourceState
import com.nostrvault.service.GlobalSearchSession
import com.nostrvault.relay.HavenBridge
import com.nostrvault.service.FeedService
import com.nostrvault.service.NostrService
import com.nostrvault.service.ZapSendService
import com.nostrvault.data.model.NoteStats
import com.nostrvault.ui.theme.*
import dagger.hilt.android.lifecycle.HiltViewModel
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableSharedFlow
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.asSharedFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.distinctUntilChanged
import kotlinx.coroutines.flow.drop
import kotlinx.coroutines.flow.map
import com.nostrvault.service.SearchBlockFilter
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import javax.inject.Inject

/**
 * Search screen. Relay scope walks the phone's own store; Global fans out to
 * the phone, the Mac relay and the NIP-50 search relays at once and streams
 * results in as each source answers (see [GlobalSearchSession]).
 */

enum class SearchResultFilter(val displayName: String) {
    ALL("All"),
    USERS("Users"),
    NOTES("Notes"),
    HASHTAGS("Hashtags"),
    LINKS("Links"),
}

enum class SearchScope(val displayName: String) {
    RELAY("Relay"),
    GLOBAL("Global"),
}

@HiltViewModel
class SearchViewModel @Inject constructor(
    private val nostrService: NostrService,
    private val configStore: ConfigStore,
    private val feedService: FeedService,
    private val zapSendService: ZapSendService,
) : ViewModel() {

    companion object {
        private const val TRENDING_THROTTLE_MS = 5_000L
        private const val MAX_TRENDING = 8
        private const val MAX_SUGGESTED = 6
        private const val MAX_RECENT = 8
        private const val NOTE_FETCH_TIMEOUT_MS = 8_000L
    }

    sealed class DirectLookupResult {
        data class NavigateToNote(val noteId: String) : DirectLookupResult()
        data class NavigateToProfile(val pubkey: String) : DirectLookupResult()
    }

    private val _query = MutableStateFlow("")
    val query = _query.asStateFlow()

    private val _results = MutableStateFlow(GlobalSearchResults())
    val results = _results.asStateFlow()

    private val _isSearching = MutableStateFlow(false)
    val isSearching = _isSearching.asStateFlow()

    private val _resultFilter = MutableStateFlow(SearchResultFilter.ALL)
    val resultFilter = _resultFilter.asStateFlow()

    private val _searchScope = MutableStateFlow(SearchScope.RELAY)
    val searchScope = _searchScope.asStateFlow()

    /** Per-source status for the running (or last) search: phone, Mac relay, each search relay. */
    private val _sources = MutableStateFlow<List<SearchSourceState>>(emptyList())
    val sources = _sources.asStateFlow()

    private var session: GlobalSearchSession? = null
    /** What the running search returned before blocks were applied. */
    private var rawResults = GlobalSearchResults()
    private var sessionJob: Job? = null
    /** Authors whose profile has already been requested for this search. */
    private val requestedAuthors = HashSet<String>()

    val profiles = nostrService.profiles

    // ── Engagement ────────────────────────────────────────────────────────
    //
    // A search result is a note. It was drawing a note's action row and
    // publishing nothing, because this screen passed no handlers; the row now
    // hides what it has no handler for, so without these it drew no row at
    // all. Same services the feed and the profile timeline act through, so a
    // like from search is the same event as a like from the feed, and the
    // liked/reposted sets are the one shared source — a note liked here shows
    // liked there without a round trip.
    val likedEventIds = feedService.likedEventIds
    val repostedEventIds = feedService.repostedEventIds
    val noteStats = feedService.noteStats

    /** Transient user-facing message (zap result). */
    private val _toast = MutableStateFlow<String?>(null)
    val toast = _toast.asStateFlow()

    fun clearToast() { _toast.value = null }

    /** Your own notes have no trust path, so they get no Web of Trust button. */
    fun isOwnNote(pubkey: String): Boolean = pubkey == nostrService.activeHexPubkey

    /** The avatar quick menu: Follow/Unfollow and Block (iOS FeedView avatar toolbar). */
    val avatarMenu = com.nostrvault.ui.components.avatarMenuActions(feedService, ::isOwnNote)

    fun likeNote(noteId: String) {
        viewModelScope.launch { feedService.likeNote(noteId) }
    }

    fun repostNote(noteId: String) {
        viewModelScope.launch { feedService.repostNote(noteId) }
    }

    fun zapNote(noteId: String, notePubkey: String) {
        viewModelScope.launch {
            // The Wallet default, same figure the feed and profile use.
            val sats = configStore.config.value.defaultZapAmount.coerceAtLeast(1)
            val result = zapSendService.zapNote(noteId, notePubkey, sats)
            _toast.value = result.fold(
                onSuccess = {
                    ZapFlight.launch(noteId)
                    "Zapped $sats sats"
                },
                onFailure = { "Zap failed: ${it.message ?: "unknown error"}" },
            )
        }
    }

    /**
     * Counts for a search result, when we have them.
     *
     * [FeedService.noteStats] is populated from the feed subscription, so this
     * is non-null exactly when the result is also a note the feed has seen.
     * Nothing here opens a second subscription to count reactions for results
     * that are not — that is the same level [NoteDetailScreen] settles for, and
     * a per-result engagement query on every keystroke's worth of results is
     * not a trade this screen should make silently.
     */
    fun statsFor(noteId: String): NoteStats? = noteStats.value[noteId]
    fun isLiked(noteId: String): Boolean = likedEventIds.value.contains(noteId)
    fun isReposted(noteId: String): Boolean = repostedEventIds.value.contains(noteId)

    // Discovery state
    private val _recentSearches = MutableStateFlow<List<String>>(emptyList())
    val recentSearches = _recentSearches.asStateFlow()

    private val _trendingHashtags = MutableStateFlow<List<String>>(emptyList())
    val trendingHashtags = _trendingHashtags.asStateFlow()

    private val _suggestedProfiles = MutableStateFlow<List<Pair<String, FeedProfile>>>(emptyList())
    val suggestedProfiles = _suggestedProfiles.asStateFlow()

    // Bech32 direct lookup
    private val _directLookup = MutableSharedFlow<DirectLookupResult>(extraBufferCapacity = 1)
    val directLookup = _directLookup.asSharedFlow()

    private val _pendingNoteId = MutableStateFlow<String?>(null)

    private var searchJob: Job? = null
    private var lastDiscoveryRefresh = 0L

    init {
        _recentSearches.value = configStore.config.value.recentSearches

        refreshDiscovery(force = true)

        // Blocking someone from a result (or unblocking) re-applies at once.
        viewModelScope.launch {
            configStore.config
                .map { it.blockedForActiveAccount() }
                .distinctUntilChanged()
                .drop(1)
                .collect {
                    if (session != null) _results.value = visible(rawResults)
                    refreshDiscovery(force = true)
                }
        }

        // Refresh discovery when feed notes change (throttled)
        viewModelScope.launch {
            feedService.notes.collect { refreshDiscovery() }
        }

        // Watch for pending note resolution in parentNotesCache
        viewModelScope.launch {
            feedService.parentNotesCache.collect { cache ->
                val pending = _pendingNoteId.value ?: return@collect
                if (cache.containsKey(pending)) {
                    _pendingNoteId.value = null
                    _isSearching.value = false
                    _directLookup.tryEmit(DirectLookupResult.NavigateToNote(pending))
                }
            }
        }

        // Also check feed notes for pending resolution
        viewModelScope.launch {
            feedService.notes.collect { notes ->
                val pending = _pendingNoteId.value ?: return@collect
                if (notes.any { it.id == pending }) {
                    _pendingNoteId.value = null
                    _isSearching.value = false
                    _directLookup.tryEmit(DirectLookupResult.NavigateToNote(pending))
                }
            }
        }
    }

    fun setQuery(text: String) {
        _query.value = text
        searchJob?.cancel()
        stopSession()

        val trimmed = text.trim()
        val lower = trimmed.lowercase()

        // Bech32 direct lookup: note1 / nevent1
        if (lower.startsWith("note1") || lower.startsWith("nevent1")) {
            val eventId = when {
                lower.startsWith("note1") -> HavenBridge.decodeNote(trimmed)
                else -> HavenBridge.decodeNevent(trimmed)
            }
            if (eventId != null) {
                val existing = feedService.findNote(eventId)
                if (existing != null) {
                    _directLookup.tryEmit(DirectLookupResult.NavigateToNote(eventId))
                } else {
                    _pendingNoteId.value = eventId
                    _isSearching.value = true
                    _results.value = GlobalSearchResults()
                    feedService.fetchMissingNote(eventId)
                    // Timeout for pending fetch
                    viewModelScope.launch {
                        delay(NOTE_FETCH_TIMEOUT_MS)
                        if (_pendingNoteId.value == eventId) {
                            _pendingNoteId.value = null
                            _isSearching.value = false
                        }
                    }
                }
                return
            }
        }

        // Bech32 direct lookup: npub1
        if (lower.startsWith("npub1")) {
            val hexPubkey = HavenBridge.decodeNpub(trimmed)
            if (hexPubkey != null) {
                val profile = profiles.value[hexPubkey] ?: FeedProfile(pubkey = hexPubkey)
                _results.value = GlobalSearchResults(profiles = listOf(profile))
                _isSearching.value = false
                return
            }
        }

        // Standard search path
        if (text.length >= 2) {
            searchJob = viewModelScope.launch {
                delay(400)
                performSearch(text)
                saveRecentSearch(text)
            }
        } else {
            _results.value = GlobalSearchResults()
            _isSearching.value = false
            refreshDiscovery(force = true)
        }
    }

    fun setResultFilter(filter: SearchResultFilter) {
        _resultFilter.value = filter
    }

    fun setSearchScope(scope: SearchScope) {
        if (_searchScope.value == scope) return
        _searchScope.value = scope
        searchJob?.cancel()
        stopSession()
        val trimmed = _query.value.trim()
        if (trimmed.length >= 2) {
            performSearch(_query.value)
        } else {
            _results.value = GlobalSearchResults()
            _isSearching.value = false
        }
    }

    /**
     * Starts a session for [query] and streams its state into the screen.
     * Relay = the phone's own store; Global = phone + Mac relay + search relays.
     */
    private fun performSearch(query: String) {
        stopSession()
        val started = nostrService.startSearch(
            query = query,
            includeGlobal = _searchScope.value == SearchScope.GLOBAL,
            follows = feedService.followedPubkeys.value.toSet(),
            wot = feedService.webOfTrustForRanking(),
        )
        if (started == null) {
            _results.value = GlobalSearchResults()
            _isSearching.value = false
            return
        }
        session = started
        requestedAuthors.clear()
        _results.value = GlobalSearchResults()
        _isSearching.value = true
        sessionJob = viewModelScope.launch {
            started.state.collect { state ->
                rawResults = state.results
                _results.value = visible(state.results)
                _sources.value = state.sources
                _isSearching.value = state.isRunning
                requestMissingAuthors(state.results.notes)
            }
        }
    }

    private fun visible(results: GlobalSearchResults): GlobalSearchResults =
        SearchBlockFilter.apply(results, feedService.blockedHexForActiveAccount()) {
            feedService.findNote(it)?.pubkey
        }

    /** Note authors from outside the follow graph have no cached profile yet. */
    private fun requestMissingAuthors(notes: List<FeedNote>) {
        val fresh = notes.asSequence().map { it.pubkey }.filter { requestedAuthors.add(it) }.toList()
        if (fresh.isNotEmpty()) nostrService.fetchMissingProfiles(fresh)
    }

    private fun stopSession() {
        sessionJob?.cancel()
        sessionJob = null
        session?.cancel()
        session = null
        rawResults = GlobalSearchResults()
        _sources.value = emptyList()
    }

    override fun onCleared() {
        stopSession()
        super.onCleared()
    }

    fun profileFor(pubkey: String): FeedProfile? = profiles.value[pubkey]

    // ── Quoted note resolution (embedded nostr:note1/nevent1 previews) ──

    val quotedNotesCache = feedService.quotedNotes

    fun quotedNoteFor(identifier: String): FeedNote? = feedService.quotedNoteFor(identifier)

    fun fetchMissingQuotedNotes(identifiers: List<String>) =
        feedService.fetchMissingQuotedNotes(identifiers)

    fun fetchMissingQuotedProfiles(identifiers: List<String>) =
        feedService.fetchMissingQuotedProfiles(identifiers)

    // ── Recent Searches ─────────────────────────────────────────────

    fun saveRecentSearch(query: String) {
        val trimmed = query.trim()
        if (trimmed.length < 2) return
        val current = _recentSearches.value.toMutableList()
        current.removeAll { it.equals(trimmed, ignoreCase = true) }
        current.add(0, trimmed)
        val capped = current.take(MAX_RECENT)
        _recentSearches.value = capped
        configStore.update { it.copy(recentSearches = capped) }
    }

    fun clearRecentSearches() {
        _recentSearches.value = emptyList()
        configStore.update { it.copy(recentSearches = emptyList()) }
    }

    // ── Discovery (Trending + Suggested) ────────────────────────────

    private fun refreshDiscovery(force: Boolean = false) {
        if (_query.value.trim().isNotEmpty()) return
        val now = System.currentTimeMillis()
        if (!force && now - lastDiscoveryRefresh < TRENDING_THROTTLE_MS) return
        lastDiscoveryRefresh = now

        viewModelScope.launch(Dispatchers.Default) {
            val hashtags = computeTrendingHashtags()
            val suggested = computeSuggestedProfiles()
            withContext(Dispatchers.Main.immediate) {
                _trendingHashtags.value = hashtags
                _suggestedProfiles.value = suggested
            }
        }
    }

    private fun computeTrendingHashtags(): List<String> {
        val counts = mutableMapOf<String, Int>()
        for (note in feedService.notes.value) {
            for (tag in note.tags) {
                if (tag.size >= 2 && tag[0] == "t") {
                    val hashtag = tag[1].lowercase()
                    counts[hashtag] = (counts[hashtag] ?: 0) + 1
                }
            }
        }
        return counts.entries
            .sortedByDescending { it.value }
            .take(MAX_TRENDING)
            .map { it.key }
    }

    private fun computeSuggestedProfiles(): List<Pair<String, FeedProfile>> {
        val postCounts = mutableMapOf<String, Int>()
        for (note in feedService.notes.value) {
            postCounts[note.pubkey] = (postCounts[note.pubkey] ?: 0) + 1
        }
        val ownPubkey = configStore.activeAccountHexPubkey.value
        val profileMap = nostrService.profiles.value
        val visible = SearchBlockFilter
            .visiblePubkeys(postCounts.keys.toList(), feedService.blockedHexForActiveAccount()).toSet()
        return postCounts
            .filter { it.key != ownPubkey && it.key in visible }
            .entries
            .sortedByDescending { it.value }
            .take(MAX_SUGGESTED)
            .mapNotNull { (pubkey, _) ->
                val profile = profileMap[pubkey]
                if (profile != null && (!profile.name.isNullOrBlank() || !profile.displayName.isNullOrBlank())) {
                    pubkey to profile
                } else null
            }
    }
}
