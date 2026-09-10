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
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.hilt.navigation.compose.hiltViewModel
import com.nostrvault.ui.components.GlassPill
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

enum class SearchScope(val displayName: String) {
    RELAY("Relay"),
    GLOBAL("Global"),
}

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
            refreshDiscovery(force = true)
        }
    }

    fun setResultFilter(filter: SearchResultFilter) {
        _resultFilter.value = filter
    }

    fun setSearchScope(scope: SearchScope) {
        _searchScope.value = scope
    }

    private fun performSearch(query: String) {
        _isSearching.value = true
        nostrService.globalSearch(query) { results ->
            _results.value = results
            _isSearching.value = false
        }
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
    val isSearching by viewModel.isSearching.collectAsState()
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
                                        SearchScope.RELAY -> NostrVaultIcons.Relay
                                        SearchScope.GLOBAL -> NostrVaultIcons.Globe
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
        if (isSearching) {
            Box(
                contentAlignment = Alignment.Center,
                modifier = Modifier
                    .fillMaxSize()
                    .padding(padding),
            ) {
                CircularProgressIndicator(color = colors.primary)
            }
        } else if (query.length < 2) {
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
        } else {
            LazyColumn(
                contentPadding = PaddingValues(
                    top = padding.calculateTopPadding(),
                    bottom = padding.calculateBottomPadding() + 88.dp,
                ),
                modifier = Modifier.fillMaxSize(),
            ) {
                // Profiles section
                if (results.profiles.isNotEmpty()) {
                    item {
                        Text(
                            text = "People",
                            color = SecondaryText,
                            fontSize = 14.sp,
                            fontWeight = FontWeight.SemiBold,
                            modifier = Modifier.padding(horizontal = 16.dp, vertical = 8.dp),
                        )
                    }
                    items(results.profiles.take(10), key = { it.pubkey }) { profile ->
                        SearchProfileRow(
                            profile = profile,
                            onClick = { onProfileClick(profile.pubkey) },
                        )
                    }
                    item {
                        HorizontalDivider(color = SeparatorColor, thickness = 0.5.dp)
                        Spacer(Modifier.height(8.dp))
                    }
                }

                // Notes section
                if (results.notes.isNotEmpty()) {
                    item {
                        Text(
                            text = "Notes",
                            color = SecondaryText,
                            fontSize = 14.sp,
                            fontWeight = FontWeight.SemiBold,
                            modifier = Modifier.padding(horizontal = 16.dp, vertical = 8.dp),
                        )
                    }
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

                // No results
                if (results.profiles.isEmpty() && results.notes.isEmpty()) {
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
private fun SearchProfileRow(
    profile: FeedProfile,
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
                    text = it,
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
