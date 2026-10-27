package com.nostrvault.ui.screens

import com.nostrvault.ui.components.ZapFlight
import androidx.compose.foundation.layout.*
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import com.nostrvault.data.local.ConfigStore
import com.nostrvault.data.model.BareNostrRefs
import com.nostrvault.data.model.FeedNote
import com.nostrvault.data.model.FeedProfile
import com.nostrvault.data.model.GlobalSearchResults
import com.nostrvault.data.model.QuoteRef
import com.nostrvault.data.model.SearchFilter
import com.nostrvault.data.model.SearchSourceState
import com.nostrvault.service.GlobalSearchSession
import com.nostrvault.service.FeedFilterEngine
import com.nostrvault.service.FeedService
import com.nostrvault.service.InterestListService
import com.nostrvault.service.SearchRecommendations
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
 * Search screen. Always Global: the phone's own store, the Mac relay and the
 * NIP-50 search relays at once, streamed in as each source answers (see
 * [GlobalSearchSession]). The who/when [SearchFilter] narrows what is shown on
 * the device and never re-runs the search (iOS #642). The relay-only search
 * lives in the Vault now.
 */

enum class SearchResultFilter(val displayName: String) {
    ALL("All"),
    USERS("Users"),
    NOTES("Notes"),
    HASHTAGS("Hashtags"),
    LINKS("Links"),
}

@HiltViewModel
class SearchViewModel @Inject constructor(
    private val nostrService: NostrService,
    private val configStore: ConfigStore,
    private val feedService: FeedService,
    private val pendingPostManager: com.nostrvault.service.PendingPostManager,
    private val zapSendService: ZapSendService,
    private val interestListService: InterestListService,
    private val notificationManager: com.nostrvault.ui.notification.NotificationManager,
) : ViewModel() {

    companion object {
        private const val TRENDING_THROTTLE_MS = 5_000L
        private const val MAX_TRENDING = 8
        private const val MAX_SUGGESTED = 6
        private const val MAX_RECENT = 8
        private const val NOTE_FETCH_TIMEOUT_MS = 8_000L
        /** Same wait as iOS SearchView before a typed query searches. */
        private const val SEARCH_DEBOUNCE_MS = 300L
    }

    sealed class DirectLookupResult {
        data class NavigateToNote(val noteId: String) : DirectLookupResult()
        data class NavigateToProfile(val pubkey: String) : DirectLookupResult()
        /** A pasted naddr1: an article or other addressable event, by its bech32. */
        data class NavigateToAddress(val naddr: String) : DirectLookupResult()
    }

    private val _query = MutableStateFlow("")
    val query = _query.asStateFlow()

    private val _results = MutableStateFlow(GlobalSearchResults())
    val results = _results.asStateFlow()

    private val _isSearching = MutableStateFlow(false)
    val isSearching = _isSearching.asStateFlow()

    private val _resultFilter = MutableStateFlow(SearchResultFilter.ALL)
    val resultFilter = _resultFilter.asStateFlow()

    /** Who and when: applied on the device to what the search returned. */
    private val _filter = MutableStateFlow(SearchFilter.ALL)
    val filter = _filter.asStateFlow()

    /** The search found something, before blocks and the filter: "No results" then offers Clear filter. */
    private val _foundAnything = MutableStateFlow(false)
    val foundAnything = _foundAnything.asStateFlow()

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

    /** Your own notes have no trust path, so they get no Web of Trust button. */
    fun isOwnNote(pubkey: String): Boolean = pubkey == nostrService.activeHexPubkey

    /** The avatar quick menu: Follow/Unfollow and Block (iOS FeedView avatar toolbar). */
    val avatarMenu = com.nostrvault.ui.components.avatarMenuActions(feedService, ::isOwnNote)

    fun likeNote(noteId: String) {
        viewModelScope.launch { feedService.likeNote(noteId) }
    }

    /** After the send-delay countdown, so the banner can undo it. */
    fun repostNote(noteId: String) = pendingPostManager.startRepost(noteId, feedService)

    fun zapNote(noteId: String, notePubkey: String) {
        viewModelScope.launch {
            // The Wallet default, same figure the feed and profile use.
            val sats = configStore.config.value.defaultZapAmount.coerceAtLeast(1)
            // The zap pill reports the result (docs/pills.md).
            notificationManager.zapping(com.nostrvault.ui.screens.feed.zapRecipientName(nostrService.profiles.value, notePubkey), sats) {
                zapSendService.zapNote(noteId, notePubkey, sats)
            }.onSuccess { ZapFlight.launch(noteId) }
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

    // "For you": ranked on device from the relay's trust graph and feed.
    private val _recommendedPeople = MutableStateFlow<List<SearchRecommendations.Person>>(emptyList())
    val recommendedPeople = _recommendedPeople.asStateFlow()

    private val _topics = MutableStateFlow<List<String>>(emptyList())
    val topics = _topics.asStateFlow()

    private val _pickedNotes = MutableStateFlow<List<FeedNote>>(emptyList())
    val pickedNotes = _pickedNotes.asStateFlow()

    // Bech32 direct lookup
    private val _directLookup = MutableSharedFlow<DirectLookupResult>(extraBufferCapacity = 1)
    val directLookup = _directLookup.asSharedFlow()

    private val _pendingNoteId = MutableStateFlow<String?>(null)
    /** A pasted note1/nevent1 being fetched: the spinner says "Looking up note..." (iOS). */
    val pendingNoteId = _pendingNoteId.asStateFlow()

    private var searchJob: Job? = null
    private var lastDiscoveryRefresh = 0L

    init {
        _recentSearches.value = configStore.config.value.recentSearches

        interestListService.refreshIfNeeded()
        refreshDiscovery(force = true)

        // Following or unfollowing a topic, or the trust graph landing,
        // changes what "For you" picks.
        viewModelScope.launch {
            interestListService.hashtags.drop(1).collect { refreshDiscovery(force = true) }
        }
        viewModelScope.launch {
            feedService.wotVouches.drop(1).collect { refreshDiscovery(force = true) }
        }

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

        // A pasted note, article or profile reference opens it — `nostr:` or
        // bare, note1/nevent1/naddr1/npub1/nprofile1, an optional `@` (iOS
        // #1250). One that does not decode searches as text.
        when (val target = BareNostrRefs.pastedTarget(text)) {
            is BareNostrRefs.Target.Note -> {
                val eventId = target.id
                if (feedService.findNote(eventId) != null) {
                    _pendingNoteId.value = null
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
            is BareNostrRefs.Target.Address -> if (QuoteRef.isLinkableKind(target.coordinate.kind)) {
                _pendingNoteId.value = null
                _isSearching.value = false
                _directLookup.tryEmit(DirectLookupResult.NavigateToAddress(target.naddr))
                return
            }
            is BareNostrRefs.Target.Profile -> {
                _pendingNoteId.value = null
                val profile = profiles.value[target.pubkey] ?: FeedProfile(pubkey = target.pubkey)
                _results.value = GlobalSearchResults(profiles = listOf(profile))
                _isSearching.value = false
                _directLookup.tryEmit(DirectLookupResult.NavigateToProfile(target.pubkey))
                return
            }
            null -> {}
        }

        // Not a reference that decodes: no note is being looked up, so
        // "Looking up note..." can't show over an ordinary search.
        _pendingNoteId.value = null

        // Standard search path
        if (text.length >= 2) {
            searchJob = viewModelScope.launch {
                delay(SEARCH_DEBOUNCE_MS)
                performSearch(text)
                saveRecentSearch(text)
            }
        } else {
            _results.value = GlobalSearchResults()
            _isSearching.value = false
            refreshDiscovery(force = true)
        }
    }

    /** The field's clear (x): empties the query and puts the result tab back on All (iOS clearSearch). */
    fun clearSearch() {
        _pendingNoteId.value = null
        setQuery("")
        _resultFilter.value = SearchResultFilter.ALL
    }

    fun setResultFilter(filter: SearchResultFilter) {
        _resultFilter.value = filter
    }

    /** Narrows what is shown, at once: the results on hand are filtered again, the relays aren't asked. */
    fun setFilter(filter: SearchFilter) {
        if (_filter.value == filter) return
        _filter.value = filter
        if (session != null) _results.value = visible(rawResults)
    }

    /** Starts a session for [query] (phone + Mac relay + search relays) and streams its state into the screen. */
    private fun performSearch(query: String) {
        stopSession()
        val started = nostrService.startSearch(
            query = query,
            includeGlobal = true,
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

    private fun visible(results: GlobalSearchResults): GlobalSearchResults {
        _foundAnything.value = results.profiles.isNotEmpty() || results.notes.isNotEmpty()
        val unblocked = SearchBlockFilter.apply(results, feedService.blockedHexForActiveAccount()) {
            feedService.findNote(it)?.pubkey
        }
        return _filter.value.apply(unblocked, nostrService.activeHexPubkey, feedService.followedPubkeys.value.toSet())
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
        _foundAnything.value = false
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
        refreshRecommendations()
    }

    /** Recomputes "For you". Called from [refreshDiscovery], so it shares its throttle. */
    private fun refreshRecommendations() {
        if (feedService.wotVouches.value == null && !feedService.wotCacheRead.value) feedService.loadWotPubkeys()
        val owner = configStore.activeAccountHexPubkey.value
        val blocked = feedService.blockedHexForActiveAccount()
        val following = feedService.followedPubkeys.value.toSet()
        val vouches = feedService.wotVouches.value.orEmpty()
        val followedTags = interestListService.hashtags.value
        val notes = feedService.notes.value
        val reacted = feedService.myReactions.value.keys

        viewModelScope.launch(Dispatchers.Default) {
            val people = SearchRecommendations.people(vouches, following, owner, blocked)
            val engaged = notes.filter { it.pubkey == owner || it.id in reacted }.map { it.tags }
            val topics = SearchRecommendations.interests(followedTags, engaged)
            val picked = SearchRecommendations.notes(
                notes.map { SearchRecommendations.Candidate(it.id, it.pubkey, it.tags, it.createdAt) },
                interests = topics.toSet(), following = following, vouches = vouches,
                owner = owner, blocked = blocked, seen = reacted,
            )
            val byId = HashMap<String, FeedNote>().apply { notes.forEach { putIfAbsent(it.id, it) } }
            val pickedNotes = picked.mapNotNull { byId[it] }.filter {
                !FeedFilterEngine.involvesBlocked(it, blocked) { id -> feedService.findNote(id)?.pubkey }
            }
            withContext(Dispatchers.Main.immediate) {
                _recommendedPeople.value = people
                _topics.value = topics
                _pickedNotes.value = pickedNotes
                if (people.isNotEmpty()) nostrService.fetchMissingProfiles(people.map { it.pubkey })
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
