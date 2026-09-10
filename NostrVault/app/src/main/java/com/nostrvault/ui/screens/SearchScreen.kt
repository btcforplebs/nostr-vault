package com.nostrvault.ui.screens

import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.platform.LocalUriHandler
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.hilt.navigation.compose.hiltViewModel
import com.nostrvault.ui.components.GlassPill
import com.nostrvault.ui.components.NostrMentions
import com.nostrvault.ui.components.GlassScaffold
import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import coil.compose.AsyncImage
import com.nostrvault.data.local.ConfigStore
import com.nostrvault.data.model.FeedNote
import com.nostrvault.data.model.FeedProfile
import com.nostrvault.data.model.GlobalSearchResults
import com.nostrvault.relay.HavenBridge
import com.nostrvault.service.FeedService
import com.nostrvault.service.NostrService
import com.nostrvault.ui.components.NoteCard
import com.nostrvault.ui.theme.*
import dagger.hilt.android.lifecycle.HiltViewModel
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableSharedFlow
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.asSharedFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import javax.inject.Inject

/**
 * NIP-50 global search screen with profiles and notes results.
 */

enum class SearchResultFilter(val displayName: String) {
    ALL("All"),
    USERS("Users"),
    NOTES("Notes"),
    HASHTAGS("Hashtags"),
    LINKS("Links"),
}

/** Search scope. CACHED filters already-loaded content instantly (offline-capable);
 *  NETWORK queries the configured NIP-50 search relays. */
enum class SearchScope(val displayName: String) {
    CACHED("Cached"),
    NETWORK("Network"),
}

/** High-level state of the active search, used to drive the results UI. */
enum class SearchStatus { IDLE, SEARCHING, RESULTS, EMPTY, ERROR }

@HiltViewModel
class SearchViewModel @Inject constructor(
    private val nostrService: NostrService,
    private val configStore: ConfigStore,
    private val feedService: FeedService,
) : ViewModel() {

    companion object {
        private const val TRENDING_THROTTLE_MS = 5_000L
        private const val MAX_TRENDING = 8
        private const val MAX_SUGGESTED = 6
        private const val MAX_RECENT = 8
        private const val NOTE_FETCH_TIMEOUT_MS = 8_000L
        private const val MAX_CACHED_PROFILES = 20
        private const val MAX_CACHED_NOTES = 30
        private const val MAX_LINKS = 30
        private val HASHTAG_REGEX = Regex("#(\\w+)")
        private val URL_REGEX = Regex("https?://\\S+")
    }

    sealed class DirectLookupResult {
        data class NavigateToNote(val noteId: String) : DirectLookupResult()
        data class NavigateToProfile(val pubkey: String) : DirectLookupResult()
    }

    private val _query = MutableStateFlow("")
    val query = _query.asStateFlow()

    private val _results = MutableStateFlow(GlobalSearchResults())
    val results = _results.asStateFlow()

    // Derived from the current result notes (filtered by the query), so the
    // Hashtags / Links filter pills show real content instead of being stubs.
    private val _hashtags = MutableStateFlow<List<String>>(emptyList())
    val hashtags = _hashtags.asStateFlow()

    private val _links = MutableStateFlow<List<String>>(emptyList())
    val links = _links.asStateFlow()

    private val _status = MutableStateFlow(SearchStatus.IDLE)
    val status = _status.asStateFlow()

    private val _resultFilter = MutableStateFlow(SearchResultFilter.ALL)
    val resultFilter = _resultFilter.asStateFlow()

    private val _searchScope = MutableStateFlow(SearchScope.NETWORK)
    val searchScope = _searchScope.asStateFlow()

    val profiles = nostrService.profiles

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
                    _status.value = SearchStatus.IDLE
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
                    _status.value = SearchStatus.IDLE
                    _directLookup.tryEmit(DirectLookupResult.NavigateToNote(pending))
                }
            }
        }
    }

    fun setQuery(text: String) {
        _query.value = text
        searchJob?.cancel()

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
                    _status.value = SearchStatus.SEARCHING
                    _results.value = GlobalSearchResults()
                    feedService.fetchMissingNote(eventId)
                    // Timeout for pending fetch
                    viewModelScope.launch {
                        delay(NOTE_FETCH_TIMEOUT_MS)
                        if (_pendingNoteId.value == eventId) {
                            _pendingNoteId.value = null
                            _status.value = SearchStatus.EMPTY
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
                _hashtags.value = emptyList()
                _links.value = emptyList()
                _status.value = SearchStatus.RESULTS
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
            nostrService.cancelGlobalSearch()
            _results.value = GlobalSearchResults()
            _hashtags.value = emptyList()
            _links.value = emptyList()
            _status.value = SearchStatus.IDLE
            refreshDiscovery(force = true)
        }
    }

    fun setResultFilter(filter: SearchResultFilter) {
        _resultFilter.value = filter
    }

    fun setSearchScope(scope: SearchScope) {
        if (_searchScope.value == scope) return
        _searchScope.value = scope
        // Re-run the active query under the new scope so the toggle takes effect.
        val q = _query.value
        if (q.trim().length >= 2) {
            searchJob?.cancel()
            searchJob = viewModelScope.launch { performSearch(q) }
        }
    }

    /** Retry the current query (used by the Network error state's Retry button). */
    fun retry() {
        val q = _query.value
        if (q.trim().length >= 2) {
            searchJob?.cancel()
            searchJob = viewModelScope.launch { performSearch(q) }
        }
    }

    private fun performSearch(query: String) {
        when (_searchScope.value) {
            SearchScope.CACHED -> performCachedSearch(query)
            SearchScope.NETWORK -> performNetworkSearch(query)
        }
    }

    /** NIP-50 network search with streaming updates and an error/empty terminal state. */
    private fun performNetworkSearch(query: String) {
        _status.value = SearchStatus.SEARCHING
        nostrService.globalSearch(
            query,
            onUpdate = { results ->
                _results.value = results
                recomputeDerived(results, query)
                if (results.profiles.isNotEmpty() || results.notes.isNotEmpty()) {
                    _status.value = SearchStatus.RESULTS
                }
            },
        ) { results, error ->
            _results.value = results
            recomputeDerived(results, query)
            _status.value = when {
                error -> SearchStatus.ERROR
                results.profiles.isEmpty() && results.notes.isEmpty() -> SearchStatus.EMPTY
                else -> SearchStatus.RESULTS
            }
        }
    }

    /** Instant filter over already-loaded profiles + feed notes (offline-capable). */
    private fun performCachedSearch(query: String) {
        nostrService.cancelGlobalSearch()
        _status.value = SearchStatus.SEARCHING
        viewModelScope.launch(Dispatchers.Default) {
            val lower = query.trim().lowercase()
            val bare = lower.removePrefix("#")
            val profileMatches = nostrService.profiles.value.values.filter { p ->
                p.name?.contains(bare, ignoreCase = true) == true ||
                    p.displayName?.contains(bare, ignoreCase = true) == true ||
                    p.about?.contains(bare, ignoreCase = true) == true ||
                    p.nip05?.contains(bare, ignoreCase = true) == true ||
                    p.pubkey.contains(bare, ignoreCase = true)
            }.take(MAX_CACHED_PROFILES)
            val noteMatches = feedService.notes.value
                .filter { it.content.contains(bare, ignoreCase = true) }
                .sortedByDescending { it.createdAt }
                .take(MAX_CACHED_NOTES)
            val res = GlobalSearchResults(profiles = profileMatches, notes = noteMatches)
            withContext(Dispatchers.Main) {
                _results.value = res
                recomputeDerived(res, query)
                _status.value = if (res.profiles.isEmpty() && res.notes.isEmpty()) {
                    SearchStatus.EMPTY
                } else {
                    SearchStatus.RESULTS
                }
            }
        }
    }

    /** Extract hashtags and links from the current result notes, filtered by the query. */
    private fun recomputeDerived(res: GlobalSearchResults, query: String) {
        val bare = query.trim().lowercase().removePrefix("#")
        val tags = LinkedHashSet<String>()
        val foundLinks = LinkedHashSet<String>()
        for (note in res.notes) {
            for (t in note.tags) {
                if (t.size >= 2 && t[0] == "t") {
                    val h = t[1].lowercase()
                    if (bare.isEmpty() || h.contains(bare)) tags.add(h)
                }
            }
            HASHTAG_REGEX.findAll(note.content).forEach { m ->
                val h = m.groupValues[1].lowercase()
                if (bare.isEmpty() || h.contains(bare)) tags.add(h)
            }
            URL_REGEX.findAll(note.content).forEach { foundLinks.add(it.value) }
        }
        _hashtags.value = tags.sorted()
        _links.value = foundLinks.toList().take(MAX_LINKS)
    }

    fun profileFor(pubkey: String): FeedProfile? = profiles.value[pubkey]

    // ── Quoted note resolution (embedded nostr:note1/nevent1 previews) ──

    val quotedNotesCache = feedService.parentNotesCache

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
        return postCounts
            .filter { it.key != ownPubkey }
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

@OptIn(ExperimentalMaterial3Api::class, ExperimentalLayoutApi::class)
@Composable
fun SearchScreen(
    onNoteClick: (String) -> Unit,
    onProfileClick: (String) -> Unit,
    viewModel: SearchViewModel = hiltViewModel(),
) {
    val query by viewModel.query.collectAsState()
    val results by viewModel.results.collectAsState()
    val hashtags by viewModel.hashtags.collectAsState()
    val links by viewModel.links.collectAsState()
    val status by viewModel.status.collectAsState()
    val resultFilter by viewModel.resultFilter.collectAsState()
    val searchScope by viewModel.searchScope.collectAsState()
    val recentSearches by viewModel.recentSearches.collectAsState()
    val trendingHashtags by viewModel.trendingHashtags.collectAsState()
    val suggestedProfiles by viewModel.suggestedProfiles.collectAsState()
    val profiles by viewModel.profiles.collectAsState()
    val quotedNotesCache by viewModel.quotedNotesCache.collectAsState()
    val colors = LocalNostrVaultColors.current

    // Fetch embedded quoted notes (nostr:note1.../nevent1...) in search results
    // plus their authors' profiles, so they resolve instead of spinning forever.
    LaunchedEffect(results) {
        val quotedIds = results.notes.flatMap { it.quotedEventIds }.distinct()
        if (quotedIds.isNotEmpty()) viewModel.fetchMissingQuotedNotes(quotedIds)
    }
    LaunchedEffect(results, quotedNotesCache) {
        val quotedIds = results.notes.flatMap { it.quotedEventIds }.distinct()
        if (quotedIds.isNotEmpty()) viewModel.fetchMissingQuotedProfiles(quotedIds)
    }

    // Handle direct bech32 lookup navigation
    LaunchedEffect(Unit) {
        viewModel.directLookup.collect { result ->
            when (result) {
                is SearchViewModel.DirectLookupResult.NavigateToNote -> onNoteClick(result.noteId)
                is SearchViewModel.DirectLookupResult.NavigateToProfile -> onProfileClick(result.pubkey)
            }
        }
    }

    GlassScaffold(
        toolbar = {
            Column(
                modifier = Modifier
                    .fillMaxWidth()
                    .statusBarsPadding()
                    .padding(horizontal = 12.dp, vertical = 8.dp),
            ) {
                // Toolbar pills row
                Row(
                    verticalAlignment = Alignment.CenterVertically,
                    modifier = Modifier
                        .fillMaxWidth()
                        .padding(bottom = 8.dp),
                ) {
                    // Leading pill: result type filter icons
                    GlassPill {
                        SearchResultFilter.entries.forEach { filter ->
                            val isSelected = filter == resultFilter
                            IconButton(
                                onClick = { viewModel.setResultFilter(filter) },
                                modifier = Modifier.size(40.dp),
                            ) {
                                Icon(
                                    imageVector = when (filter) {
                                        SearchResultFilter.ALL -> NostrVaultIcons.Layers
                                        SearchResultFilter.USERS -> NostrVaultIcons.Profile
                                        SearchResultFilter.NOTES -> NostrVaultIcons.Document
                                        SearchResultFilter.HASHTAGS -> NostrVaultIcons.TagIcon
                                        SearchResultFilter.LINKS -> NostrVaultIcons.LinkIcon
                                    },
                                    contentDescription = filter.displayName,
                                    tint = if (isSelected) colors.primary else SecondaryText,
                                    modifier = Modifier.size(25.dp),
                                )
                            }
                        }
                    }

                    Spacer(Modifier.weight(1f))

                    // Trailing pill: search scope (Relay / Global)
                    GlassPill {
                        SearchScope.entries.forEach { scope ->
                            val isSelected = scope == searchScope
                            IconButton(
                                onClick = { viewModel.setSearchScope(scope) },
                                modifier = Modifier.size(40.dp),
                            ) {
                                Icon(
                                    imageVector = when (scope) {
                                        SearchScope.CACHED -> NostrVaultIcons.Relay
                                        SearchScope.NETWORK -> NostrVaultIcons.Globe
                                    },
                                    contentDescription = scope.displayName,
                                    tint = if (isSelected) colors.primary else SecondaryText,
                                    modifier = Modifier.size(25.dp),
                                )
                            }
                        }
                    }
                }

                // Search text field
                OutlinedTextField(
                    value = query,
                    onValueChange = viewModel::setQuery,
                    placeholder = { Text("Search Nostr...", color = PlaceholderText) },
                    leadingIcon = {
                        Icon(NostrVaultIcons.Search, null, tint = SecondaryText)
                    },
                    trailingIcon = {
                        if (query.isNotEmpty()) {
                            IconButton(onClick = { viewModel.setQuery("") }) {
                                Icon(NostrVaultIcons.Dismiss, "Clear", tint = SecondaryText)
                            }
                        }
                    },
                    singleLine = true,
                    colors = OutlinedTextFieldDefaults.colors(
                        focusedBorderColor = colors.primary,
                        unfocusedBorderColor = SeparatorColor,
                        cursorColor = colors.primary,
                    ),
                    shape = RoundedCornerShape(12.dp),
                    modifier = Modifier.fillMaxWidth(),
                )
            }
        },
    ) { padding ->
        if (query.length < 2) {
            // Empty state with discovery sections
            val hasDiscovery = recentSearches.isNotEmpty() ||
                trendingHashtags.isNotEmpty() ||
                suggestedProfiles.isNotEmpty()

            if (hasDiscovery) {
                LazyColumn(
                    contentPadding = PaddingValues(
                        top = padding.calculateTopPadding() + 16.dp,
                        bottom = padding.calculateBottomPadding() + 88.dp,
                        start = 16.dp,
                        end = 16.dp,
                    ),
                    modifier = Modifier.fillMaxSize(),
                ) {
                    // Recent searches section
                    if (recentSearches.isNotEmpty()) {
                        item {
                            Row(
                                modifier = Modifier.fillMaxWidth(),
                                horizontalArrangement = Arrangement.SpaceBetween,
                                verticalAlignment = Alignment.CenterVertically,
                            ) {
                                Text(
                                    "Recent",
                                    color = SecondaryText,
                                    fontSize = 13.sp,
                                    fontWeight = FontWeight.SemiBold,
                                )
                                TextButton(onClick = { viewModel.clearRecentSearches() }) {
                                    Text("Clear", color = TertiaryText, fontSize = 12.sp)
                                }
                            }
                        }
                        item {
                            FlowRow(
                                horizontalArrangement = Arrangement.spacedBy(6.dp),
                                verticalArrangement = Arrangement.spacedBy(6.dp),
                            ) {
                                recentSearches.forEach { recent ->
                                    RecentSearchChip(
                                        query = recent,
                                        onClick = { viewModel.setQuery(recent) },
                                    )
                                }
                            }
                            Spacer(Modifier.height(24.dp))
                        }
                    }

                    // Trending hashtags section
                    if (trendingHashtags.isNotEmpty()) {
                        item {
                            Text(
                                "Trending",
                                color = SecondaryText,
                                fontSize = 13.sp,
                                fontWeight = FontWeight.SemiBold,
                            )
                            Spacer(Modifier.height(10.dp))
                        }
                        item {
                            FlowRow(
                                horizontalArrangement = Arrangement.spacedBy(6.dp),
                                verticalArrangement = Arrangement.spacedBy(6.dp),
                            ) {
                                trendingHashtags.forEach { tag ->
                                    TrendingHashtagChip(
                                        tag = tag,
                                        onClick = { viewModel.setQuery("#$tag") },
                                        colors = colors,
                                    )
                                }
                            }
                            Spacer(Modifier.height(24.dp))
                        }
                    }

                    // Suggested profiles section
                    if (suggestedProfiles.isNotEmpty()) {
                        item {
                            Text(
                                "Active in your feed",
                                color = SecondaryText,
                                fontSize = 13.sp,
                                fontWeight = FontWeight.SemiBold,
                            )
                            Spacer(Modifier.height(10.dp))
                        }
                        items(suggestedProfiles, key = { it.first }) { (pubkey, profile) ->
                            SuggestedProfileRow(
                                profile = profile,
                                onClick = { onProfileClick(pubkey) },
                            )
                        }
                    }
                }
            } else {
                // Fallback empty state
                Box(
                    contentAlignment = Alignment.Center,
                    modifier = Modifier
                        .fillMaxSize()
                        .padding(padding),
                ) {
                    Column(horizontalAlignment = Alignment.CenterHorizontally) {
                        Icon(
                            imageVector = NostrVaultIcons.Search,
                            contentDescription = null,
                            tint = TertiaryText,
                            modifier = Modifier.size(48.dp),
                        )
                        Spacer(Modifier.height(12.dp))
                        Text(
                            text = "Search for people and notes",
                            color = SecondaryText,
                            fontSize = 16.sp,
                        )
                    }
                }
            }
        } else if (status == SearchStatus.SEARCHING) {
            Box(
                contentAlignment = Alignment.Center,
                modifier = Modifier
                    .fillMaxSize()
                    .padding(padding),
            ) {
                CircularProgressIndicator(color = colors.primary)
            }
        } else if (status == SearchStatus.ERROR) {
            Box(
                contentAlignment = Alignment.Center,
                modifier = Modifier
                    .fillMaxSize()
                    .padding(padding),
            ) {
                Column(
                    horizontalAlignment = Alignment.CenterHorizontally,
                    modifier = Modifier.padding(32.dp),
                ) {
                    Icon(
                        imageVector = NostrVaultIcons.Globe,
                        contentDescription = null,
                        tint = TertiaryText,
                        modifier = Modifier.size(40.dp),
                    )
                    Spacer(Modifier.height(12.dp))
                    Text(
                        text = "Couldn't reach search relays",
                        color = SecondaryText,
                        fontSize = 15.sp,
                    )
                    Spacer(Modifier.height(12.dp))
                    Button(
                        onClick = { viewModel.retry() },
                        colors = ButtonDefaults.buttonColors(containerColor = colors.primary),
                    ) {
                        Text("Retry")
                    }
                }
            }
        } else {
            val showUsers = resultFilter == SearchResultFilter.ALL || resultFilter == SearchResultFilter.USERS
            val showNotes = resultFilter == SearchResultFilter.ALL || resultFilter == SearchResultFilter.NOTES
            val showHashtags = resultFilter == SearchResultFilter.ALL || resultFilter == SearchResultFilter.HASHTAGS
            val showLinks = resultFilter == SearchResultFilter.ALL || resultFilter == SearchResultFilter.LINKS
            val hasUsers = showUsers && results.profiles.isNotEmpty()
            val hasNotes = showNotes && results.notes.isNotEmpty()
            val hasHashtags = showHashtags && hashtags.isNotEmpty()
            val hasLinks = showLinks && links.isNotEmpty()
            val uriHandler = LocalUriHandler.current

            LazyColumn(
                contentPadding = PaddingValues(
                    top = padding.calculateTopPadding(),
                    bottom = padding.calculateBottomPadding() + 88.dp,
                ),
                modifier = Modifier.fillMaxSize(),
            ) {
                // People section
                if (hasUsers) {
                    item { SearchSectionHeader("People") }
                    items(results.profiles.take(10), key = { it.pubkey }) { profile ->
                        SearchProfileRow(
                            profile = profile,
                            profiles = profiles,
                            onClick = { onProfileClick(profile.pubkey) },
                        )
                    }
                    item {
                        HorizontalDivider(color = SeparatorColor, thickness = 0.5.dp)
                        Spacer(Modifier.height(8.dp))
                    }
                }

                // Notes section
                if (hasNotes) {
                    item { SearchSectionHeader("Notes") }
                    items(results.notes, key = { it.id }) { note ->
                        val quotedNotesMap = remember(note.id, note.quotedEventIds, quotedNotesCache) {
                            note.quotedEventIds.mapNotNull { qid ->
                                viewModel.quotedNoteFor(qid)?.let { qid to it }
                            }.toMap()
                        }
                        NoteCard(
                            note = note,
                            profile = viewModel.profileFor(note.pubkey),
                            stats = null,
                            profiles = profiles,
                            quotedNotes = quotedNotesMap,
                            onNoteClick = onNoteClick,
                            onProfileClick = onProfileClick,
                        )
                        HorizontalDivider(color = SeparatorColor, thickness = 0.5.dp)
                    }
                }

                // Hashtags section
                if (hasHashtags) {
                    item { SearchSectionHeader("Hashtags") }
                    item {
                        FlowRow(
                            horizontalArrangement = Arrangement.spacedBy(6.dp),
                            verticalArrangement = Arrangement.spacedBy(6.dp),
                            modifier = Modifier.padding(horizontal = 16.dp),
                        ) {
                            hashtags.forEach { tag ->
                                TrendingHashtagChip(
                                    tag = tag,
                                    onClick = { viewModel.setQuery("#$tag") },
                                    colors = colors,
                                )
                            }
                        }
                        Spacer(Modifier.height(8.dp))
                    }
                }

                // Links section
                if (hasLinks) {
                    item { SearchSectionHeader("Links") }
                    items(links, key = { it }) { link ->
                        SearchLinkRow(url = link, onClick = { uriHandler.openUri(link) })
                    }
                }

                // No results
                if (!hasUsers && !hasNotes && !hasHashtags && !hasLinks) {
                    item {
                        Box(
                            contentAlignment = Alignment.Center,
                            modifier = Modifier
                                .fillMaxWidth()
                                .padding(32.dp),
                        ) {
                            Text("No results found", color = SecondaryText, fontSize = 15.sp)
                        }
                    }
                }
            }
        }
    }
}

@Composable
private fun SearchSectionHeader(title: String) {
    Text(
        text = title,
        color = SecondaryText,
        fontSize = 14.sp,
        fontWeight = FontWeight.SemiBold,
        modifier = Modifier.padding(horizontal = 16.dp, vertical = 8.dp),
    )
}

@Composable
private fun SearchLinkRow(url: String, onClick: () -> Unit) {
    Row(
        verticalAlignment = Alignment.CenterVertically,
        modifier = Modifier
            .fillMaxWidth()
            .clickable(onClick = onClick)
            .padding(horizontal = 16.dp, vertical = 10.dp),
    ) {
        Icon(
            imageVector = NostrVaultIcons.LinkIcon,
            contentDescription = null,
            tint = SecondaryText,
            modifier = Modifier.size(18.dp),
        )
        Spacer(Modifier.width(12.dp))
        Text(
            text = url,
            color = PrimaryText.copy(alpha = 0.85f),
            fontSize = 14.sp,
            maxLines = 1,
            overflow = TextOverflow.Ellipsis,
        )
    }
}

@Composable
private fun SearchProfileRow(
    profile: FeedProfile,
    profiles: Map<String, FeedProfile> = emptyMap(),
    onClick: () -> Unit,
) {
    Row(
        verticalAlignment = Alignment.CenterVertically,
        modifier = Modifier
            .fillMaxWidth()
            .clickable(onClick = onClick)
            .padding(horizontal = 16.dp, vertical = 8.dp),
    ) {
        AsyncImage(
            model = profile.pictureURL,
            contentDescription = null,
            contentScale = ContentScale.Crop,
            modifier = Modifier
                .size(44.dp)
                .clip(CircleShape),
        )
        Spacer(Modifier.width(12.dp))
        Column(modifier = Modifier.weight(1f)) {
            Text(
                text = profile.bestName,
                color = PrimaryText,
                fontSize = 15.sp,
                fontWeight = FontWeight.SemiBold,
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
            )
            profile.nip05?.let {
                Text(text = it, color = SecondaryText, fontSize = 13.sp)
            }
            profile.about?.takeIf { it.isNotBlank() }?.let {
                Text(
                    text = NostrMentions.toPlainText(it, profiles).replace("\n", " "),
                    color = TertiaryText,
                    fontSize = 13.sp,
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis,
                )
            }
        }
    }
}

@Composable
private fun RecentSearchChip(query: String, onClick: () -> Unit) {
    Surface(
        onClick = onClick,
        shape = RoundedCornerShape(14.dp),
        color = SeparatorColor.copy(alpha = 0.12f),
    ) {
        Row(
            verticalAlignment = Alignment.CenterVertically,
            modifier = Modifier.padding(horizontal = 10.dp, vertical = 6.dp),
        ) {
            Icon(
                imageVector = NostrVaultIcons.History,
                contentDescription = null,
                tint = SecondaryText,
                modifier = Modifier.size(12.dp),
            )
            Spacer(Modifier.width(4.dp))
            Text(
                text = query,
                color = PrimaryText.copy(alpha = 0.8f),
                fontSize = 12.sp,
                fontWeight = FontWeight.Medium,
            )
        }
    }
}

@Composable
private fun TrendingHashtagChip(
    tag: String,
    onClick: () -> Unit,
    colors: NostrVaultColorScheme,
) {
    Surface(
        onClick = onClick,
        shape = RoundedCornerShape(14.dp),
        color = colors.primary.copy(alpha = 0.12f),
    ) {
        Text(
            text = "#$tag",
            color = colors.primary,
            fontSize = 12.sp,
            fontWeight = FontWeight.Medium,
            modifier = Modifier.padding(horizontal = 10.dp, vertical = 6.dp),
        )
    }
}

@Composable
private fun SuggestedProfileRow(
    profile: FeedProfile,
    onClick: () -> Unit,
) {
    Row(
        verticalAlignment = Alignment.CenterVertically,
        modifier = Modifier
            .fillMaxWidth()
            .clickable(onClick = onClick)
            .padding(horizontal = 8.dp, vertical = 6.dp),
    ) {
        AsyncImage(
            model = profile.pictureURL,
            contentDescription = null,
            contentScale = ContentScale.Crop,
            modifier = Modifier
                .size(34.dp)
                .clip(CircleShape),
        )
        Spacer(Modifier.width(10.dp))
        Column(modifier = Modifier.weight(1f)) {
            Text(
                text = profile.bestName,
                color = PrimaryText,
                fontSize = 13.sp,
                fontWeight = FontWeight.Medium,
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
            )
            profile.nip05?.takeIf { it.isNotBlank() }?.let {
                Text(text = it, color = SecondaryText, fontSize = 11.sp, maxLines = 1)
            }
        }
        Icon(
            imageVector = NostrVaultIcons.Navigate,
            contentDescription = null,
            tint = SecondaryText.copy(alpha = 0.5f),
            modifier = Modifier.size(14.dp),
        )
    }
}
