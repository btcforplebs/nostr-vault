package com.nostrvault.ui.screens

import com.nostrvault.ui.navigation.FloatingButtonRow.floatingRowButton
import com.nostrvault.data.model.SearchFilter
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.lazy.itemsIndexed
import androidx.compose.foundation.gestures.detectTapGestures
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.platform.LocalFocusManager
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.ui.draw.shadow
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.foundation.background
import com.nostrvault.ui.components.blockedWhen
import com.nostrvault.ui.components.chromeFab
import com.nostrvault.ui.components.rememberChromeFolded
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.hilt.navigation.compose.hiltViewModel
import com.nostrvault.ui.components.GlassPill
import com.nostrvault.ui.components.GlassScaffold
import com.nostrvault.ui.components.NoteCard
import com.nostrvault.ui.components.TrustWebDialog
import com.nostrvault.ui.navigation.LocalOpenHashtag
import com.nostrvault.ui.navigation.Screen
import com.nostrvault.ui.navigation.TabReselect
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.ui.platform.LocalSoftwareKeyboardController
import com.nostrvault.ui.theme.*
import kotlinx.coroutines.flow.map

@OptIn(ExperimentalMaterial3Api::class, ExperimentalLayoutApi::class)
@Composable
fun SearchScreen(
    onNoteClick: (String) -> Unit,
    /** Where a quoted long-form post opens; the note screen would show its Markdown source. */
    onArticleClick: (String) -> Unit,
    onProfileClick: (String) -> Unit,
    onReply: (String) -> Unit,
    onQuote: (String) -> Unit,
    onCompose: () -> Unit,
    /** Where a pasted naddr1 opens (the address screen asks the user's relays). */
    onAddressClick: (String) -> Unit = {},
    viewModel: SearchViewModel = hiltViewModel(),
) {
    val query by viewModel.query.collectAsState()
    val results by viewModel.results.collectAsState()
    val isSearching by viewModel.isSearching.collectAsState()
    val resultFilter by viewModel.resultFilter.collectAsState()
    val searchFilter by viewModel.filter.collectAsState()
    val foundAnything by viewModel.foundAnything.collectAsState()
    val sources by viewModel.sources.collectAsState()
    val pendingNoteId by viewModel.pendingNoteId.collectAsState()
    val recentSearches by viewModel.recentSearches.collectAsState()
    val trendingHashtags by viewModel.trendingHashtags.collectAsState()
    val suggestedProfiles by viewModel.suggestedProfiles.collectAsState()
    val recommendedPeople by viewModel.recommendedPeople.collectAsState()
    val topics by viewModel.topics.collectAsState()
    val pickedNotes by viewModel.pickedNotes.collectAsState()
    val profiles by viewModel.profiles.collectAsState()
    val quotedNotesCache by viewModel.quotedNotesCache.collectAsState()
    val likedIds by viewModel.likedEventIds.collectAsState()
    val repostedIds by viewModel.repostedEventIds.collectAsState()
    val colors = LocalNostrVaultColors.current
    // The post bar's Web of Trust button: the author whose map is open.
    var trustWebAuthor by remember { mutableStateOf<String?>(null) }
    // Tapping the Search tab while it shows scrolls to the top, as iOS does.
    val discoveryListState = rememberLazyListState()
    val resultsListState = rememberLazyListState()
    LaunchedEffect(Unit) {
        TabReselect.of(Screen.Search).collect {
            discoveryListState.animateScrollToItem(0)
            resultsListState.animateScrollToItem(0)
        }
    }

    // Hashtags and links are read out of the matching notes, as on the iPhone.
    val hashtagResults = remember(results.notes, query) { SearchResultSections.hashtags(results.notes, query) }
    val linkResults = remember(results.notes) { SearchResultSections.links(results.notes) }
    val anyResults = results.profiles.isNotEmpty() || results.notes.isNotEmpty()
    val showUsers = SearchResultSections.shows(resultFilter, SearchResultFilter.USERS) && results.profiles.isNotEmpty()
    val showNotes = SearchResultSections.shows(resultFilter, SearchResultFilter.NOTES) && results.notes.isNotEmpty()
    val showHashtags = SearchResultSections.shows(resultFilter, SearchResultFilter.HASHTAGS) && hashtagResults.isNotEmpty()
    val showLinks = SearchResultSections.shows(resultFilter, SearchResultFilter.LINKS) && linkResults.isNotEmpty()
    val openHashtag = LocalOpenHashtag.current
    val keyboard = LocalSoftwareKeyboardController.current
    val focusManager = LocalFocusManager.current
    val hideKeyboard = { keyboard?.hide(); focusManager.clearFocus() }
    val namedPeople = remember(recommendedPeople, profiles) { namedRecommendedPeople(recommendedPeople, profiles) }

    // One note card for search results and "For you" picks alike.
    val noteCard: @Composable (com.nostrvault.data.model.FeedNote) -> Unit = { note ->
        val quotedNotesMap = remember(note.id, note.quotedEventIds, quotedNotesCache) {
            note.quotedEventIds.mapNotNull { qid ->
                viewModel.quotedNoteFor(qid)?.let { qid to it }
            }.toMap()
        }
        NoteCard(
            note = note,
            avatarMenu = viewModel.avatarMenu,
            profile = viewModel.profileFor(note.pubkey),
            profiles = profiles,
            quotedNotes = quotedNotesMap,
            isLiked = note.effectiveEventId in likedIds,
            isReposted = note.effectiveEventId in repostedIds,
            onNoteClick = onNoteClick,
            onArticleClick = onArticleClick,
            onProfileClick = onProfileClick,
            onLike = viewModel::likeNote,
            onRepost = viewModel::repostNote,
            onReply = onReply,
            onQuote = onQuote,
            onZap = { viewModel.zapNote(note.effectiveEventId, note.effectiveAuthor) },
            onTrustWeb = if (viewModel.isOwnNote(note.effectiveAuthor)) null else ({ author: String -> trustWebAuthor = author }),
        )
        HorizontalDivider(color = SeparatorColor, thickness = 0.5.dp)
    }


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
                is SearchViewModel.DirectLookupResult.NavigateToAddress -> onAddressClick(result.naddr)
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
                                    imageVector = filter.icon,
                                    contentDescription = filter.displayName,
                                    tint = if (isSelected) colors.primary else SecondaryText,
                                    modifier = Modifier.size(25.dp),
                                )
                            }
                        }
                    }

                    Spacer(Modifier.weight(1f))

                    // Trailing pill: who/when filter. Search is always Global;
                    // relay-only search is in the Vault (iOS #642).
                    GlassPill {
                        SearchFilterMenu(filter = searchFilter, onChange = viewModel::setFilter, accent = colors.primary)
                    }
                }

                // Return only hides the keyboard, as on the iPhone: typing
                // already searches. The clear (x) also puts the tab back on All.
                SearchQueryField(
                    query = query,
                    onQueryChange = viewModel::setQuery,
                    onClear = { viewModel.clearSearch(); hideKeyboard() },
                    onSubmit = hideKeyboard,
                    accent = colors.primary,
                )
                SearchFilterCaption(filter = searchFilter, onClear = { viewModel.setFilter(SearchFilter.ALL) }, accent = colors.primary)
            }
        },
        floatingActionButton = {
            // The same gradient "Post" capsule as the feed, folding with the bars.
            val folded by rememberChromeFolded()
            Box(Modifier.chromeFab().blockedWhen(folded)) {
                Surface(
                    onClick = onCompose,
                    shape = RoundedCornerShape(50),
                    color = Color.Transparent,
                    modifier = Modifier
                        .floatingRowButton()
                        .shadow(
                            elevation = 8.dp,
                            shape = RoundedCornerShape(50),
                            ambientColor = colors.primary.copy(alpha = 0.35f),
                            spotColor = colors.primary.copy(alpha = 0.35f),
                        ),
                ) {
                    Row(
                        verticalAlignment = Alignment.CenterVertically,
                        horizontalArrangement = Arrangement.spacedBy(6.dp),
                        modifier = Modifier
                            .background(Brush.linearGradient(listOf(colors.primary, colors.primaryLight)), RoundedCornerShape(50))
                            .height(48.dp)
                            .padding(horizontal = 18.dp),
                    ) {
                        Icon(NostrVaultIcons.Compose, contentDescription = null, tint = Color.White, modifier = Modifier.size(18.dp))
                        Text("Post", color = Color.White, fontSize = 14.sp, fontWeight = FontWeight.Bold)
                    }
                }
            }
        },
    ) { padding ->
      // A tap on the background hides the keyboard (iOS onTapGesture); rows keep their own taps.
      Box(Modifier.fillMaxSize().pointerInput(Unit) { detectTapGestures { hideKeyboard() } }) {
        if (query.length < 2) {
            // Empty state with discovery sections
            val hasDiscovery = recentSearches.isNotEmpty() ||
                trendingHashtags.isNotEmpty() ||
                suggestedProfiles.isNotEmpty() ||
                namedPeople.isNotEmpty() || topics.isNotEmpty() || pickedNotes.isNotEmpty()

            if (hasDiscovery) {
                LazyColumn(
                    state = discoveryListState,
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

                    searchRecommendationsSection(
                        people = namedPeople,
                        topics = topics,
                        notes = pickedNotes,
                        colors = colors,
                        onProfile = onProfileClick,
                        onTopic = { tag -> if (openHashtag != null) openHashtag(tag) else viewModel.setQuery("#$tag") },
                        noteContent = noteCard,
                    )

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
                                        // Opens the hashtag's own feed: posts tagged with it, not a word search.
                                        onClick = {
                                            if (openHashtag != null) openHashtag(tag) else viewModel.setQuery("#$tag")
                                        },
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
                SearchFallbackState(Modifier.padding(padding))
            }
        } else {
            Column(
                Modifier
                    .fillMaxSize()
                    .padding(top = padding.calculateTopPadding()),
            ) {
                // Per-source status stays above the results while they stream in.
                if (sources.isNotEmpty()) {
                    SearchSourcesRow(sources = sources)
                    HorizontalDivider(color = SeparatorColor, thickness = 0.5.dp)
                }
                val stateModifier = Modifier.weight(1f).padding(bottom = padding.calculateBottomPadding())
                if (!anyResults) {
                    if (isSearching) {
                        SearchLoadingState(lookingUpNote = pendingNoteId != null, accent = colors.primary, modifier = stateModifier)
                    } else {
                        SearchNoResultsState(
                            showClearFilter = searchFilter.isActive && foundAnything,
                            onClearFilter = { viewModel.setFilter(SearchFilter.ALL) },
                            accent = colors.primary,
                            modifier = stateModifier,
                        )
                    }
                } else {
                    val firstSection = when {
                        showUsers -> SearchResultFilter.USERS
                        showNotes -> SearchResultFilter.NOTES
                        showHashtags -> SearchResultFilter.HASHTAGS
                        else -> SearchResultFilter.LINKS
                    }
                    LazyColumn(
                        state = resultsListState,
                        contentPadding = PaddingValues(bottom = padding.calculateBottomPadding() + 88.dp),
                        modifier = Modifier.weight(1f).fillMaxWidth(),
                    ) {
                        // Every matching person, the way the iPhone lists them;
                        // the Users tab is how to see only people.
                        if (showUsers) {
                            item(key = "users-header") { SearchSectionHeader("Users", firstSection == SearchResultFilter.USERS) }
                            itemsIndexed(results.profiles, key = { _, it -> it.pubkey }) { i, profile ->
                                SearchProfileRow(
                                    profile = profile,
                                    profiles = profiles,
                                    onClick = { onProfileClick(profile.pubkey) },
                                    modifier = Modifier.searchSectionRow(last = i == results.profiles.lastIndex),
                                )
                            }
                        }
                        if (showNotes) {
                            item(key = "notes-header") { SearchSectionHeader("Notes", firstSection == SearchResultFilter.NOTES) }
                            items(results.notes, key = { it.id }) { note -> noteCard(note) }
                        }
                        // Hashtags written in the matching notes
                        if (showHashtags) {
                            item(key = "hashtags-header") { SearchSectionHeader("Hashtags", firstSection == SearchResultFilter.HASHTAGS) }
                            itemsIndexed(hashtagResults, key = { _, it -> "tag-$it" }) { i, tag ->
                                SearchHashtagRow(
                                    tag = tag,
                                    onClick = { viewModel.setQuery("#$tag") },
                                    colors = colors,
                                    modifier = Modifier.searchSectionRow(last = i == hashtagResults.lastIndex),
                                )
                            }
                        }
                        // Links the matching notes contain
                        if (showLinks) {
                            item(key = "links-header") { SearchSectionHeader("Links", firstSection == SearchResultFilter.LINKS) }
                            itemsIndexed(linkResults, key = { _, it -> "link-${it.url}" }) { i, link ->
                                SearchLinkRow(
                                    link = link,
                                    colors = colors,
                                    modifier = Modifier.searchSectionRow(last = i == linkResults.lastIndex),
                                )
                            }
                        }
                        if (!showUsers && !showNotes && !showHashtags && !showLinks) {
                            item(key = "empty-filter") { SearchEmptyTabState(resultFilter, query) }
                        }
                    }
                }
            }
        }
      }
    }

    trustWebAuthor?.let { author ->
        TrustWebDialog(
            author = author,
            initialPath = null,
            onProfileClick = onProfileClick,
            onDismiss = { trustWebAuthor = null },
        )
    }
}
