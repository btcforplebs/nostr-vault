package com.nostrvault.ui.screens

import com.nostrvault.ui.navigation.FloatingButtonRow.floatingRowButton
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
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
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.hilt.navigation.compose.hiltViewModel
import com.nostrvault.ui.components.GlassPill
import com.nostrvault.ui.components.GlassScaffold
import androidx.compose.ui.platform.LocalContext
import android.widget.Toast
import com.nostrvault.ui.components.NoteCard
import com.nostrvault.ui.components.TrustWebDialog
import com.nostrvault.ui.navigation.HashtagLink
import com.nostrvault.ui.navigation.LocalOpenHashtag
import androidx.compose.foundation.text.KeyboardActions
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.ui.text.input.ImeAction
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
    viewModel: SearchViewModel = hiltViewModel(),
) {
    val query by viewModel.query.collectAsState()
    val results by viewModel.results.collectAsState()
    val isSearching by viewModel.isSearching.collectAsState()
    val resultFilter by viewModel.resultFilter.collectAsState()
    val searchScope by viewModel.searchScope.collectAsState()
    val sources by viewModel.sources.collectAsState()
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
    val toast by viewModel.toast.collectAsState()
    val colors = LocalNostrVaultColors.current
    // The post bar's Web of Trust button: the author whose map is open.
    var trustWebAuthor by remember { mutableStateOf<String?>(null) }

    // Hashtags and links are read out of the matching notes, as on the iPhone.
    val hashtagResults = remember(results.notes, query) { SearchResultSections.hashtags(results.notes, query) }
    val linkResults = remember(results.notes) { SearchResultSections.links(results.notes) }
    val anyResults = results.profiles.isNotEmpty() || results.notes.isNotEmpty()
    val showUsers = SearchResultSections.shows(resultFilter, SearchResultFilter.USERS) && results.profiles.isNotEmpty()
    val showNotes = SearchResultSections.shows(resultFilter, SearchResultFilter.NOTES) && results.notes.isNotEmpty()
    val showHashtags = SearchResultSections.shows(resultFilter, SearchResultFilter.HASHTAGS) && hashtagResults.isNotEmpty()
    val showLinks = SearchResultSections.shows(resultFilter, SearchResultFilter.LINKS) && linkResults.isNotEmpty()
    val context = LocalContext.current
    val openHashtag = LocalOpenHashtag.current
    val keyboard = LocalSoftwareKeyboardController.current
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

    // Zap feedback, the same way the profile timeline reports it.
    LaunchedEffect(toast) {
        toast?.let {
            Toast.makeText(context, it, Toast.LENGTH_SHORT).show()
            viewModel.clearToast()
        }
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
                    placeholder = { Text("Search users, notes, hashtags...", color = PlaceholderText) },
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
                    // "#bitcoin" opens the hashtag's feed instead of a word search.
                    keyboardOptions = KeyboardOptions(imeAction = ImeAction.Search),
                    // Anything else is already searching as it is typed.
                    keyboardActions = KeyboardActions(onSearch = {
                        keyboard?.hide()
                        val tag = HashtagLink.fromSearchQuery(query)
                        if (tag != null && openHashtag != null) openHashtag(tag)
                    }),
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
        if (query.length < 2) {
            // Empty state with discovery sections
            val hasDiscovery = recentSearches.isNotEmpty() ||
                trendingHashtags.isNotEmpty() ||
                suggestedProfiles.isNotEmpty() ||
                namedPeople.isNotEmpty() || topics.isNotEmpty() || pickedNotes.isNotEmpty()

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
                            text = "Search",
                            color = SecondaryText,
                            fontSize = 16.sp,
                            fontWeight = FontWeight.SemiBold,
                        )
                        Spacer(Modifier.height(4.dp))
                        Text(
                            text = "Find users, notes, hashtags and links\nOr paste a note1 or nevent1 ID",
                            color = TertiaryText,
                            fontSize = 14.sp,
                            textAlign = TextAlign.Center,
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
                // Per-source status: which sources are still searching, what
                // each found, and why a silent one gave no answer.
                if (sources.isNotEmpty()) {
                    item(key = "search-sources") {
                        SearchSourcesRow(sources = sources, colors = colors)
                    }
                }

                if (isSearching && !anyResults) {
                    item(key = "search-spinner") {
                        Box(
                            contentAlignment = Alignment.Center,
                            modifier = Modifier
                                .fillMaxWidth()
                                .padding(32.dp),
                        ) {
                            CircularProgressIndicator(color = colors.primary)
                        }
                    }
                }

                // Profiles section. Every match, the way the iPhone lists them;
                // the Users chip is how to see only people.
                if (showUsers) {
                    item {
                        Text(
                            text = "Users",
                            color = SecondaryText,
                            fontSize = 14.sp,
                            fontWeight = FontWeight.SemiBold,
                            modifier = Modifier.padding(horizontal = 16.dp, vertical = 8.dp),
                        )
                    }
                    items(results.profiles, key = { it.pubkey }) { profile ->
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
                if (showNotes) {
                    item {
                        Text(
                            text = "Notes",
                            color = SecondaryText,
                            fontSize = 14.sp,
                            fontWeight = FontWeight.SemiBold,
                            modifier = Modifier.padding(horizontal = 16.dp, vertical = 8.dp),
                        )
                    }
                    items(results.notes, key = { it.id }) { note -> noteCard(note) }
                }

                // Hashtags written in the matching notes
                if (showHashtags) {
                    item(key = "hashtags-header") {
                        SearchSectionHeader("Hashtags")
                    }
                    items(hashtagResults, key = { "tag-$it" }) { tag ->
                        SearchHashtagRow(
                            tag = tag,
                            onClick = { viewModel.setQuery("#$tag") },
                            colors = colors,
                        )
                    }
                    item(key = "hashtags-end") { Spacer(Modifier.height(8.dp)) }
                }

                // Links the matching notes contain
                if (showLinks) {
                    item(key = "links-header") {
                        SearchSectionHeader("Links")
                    }
                    items(linkResults, key = { "link-${it.url}" }) { link ->
                        SearchLinkRow(link = link, colors = colors)
                    }
                    item(key = "links-end") { Spacer(Modifier.height(8.dp)) }
                }

                // No results
                if (!isSearching && !anyResults) {
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
                } else if (!isSearching && !showUsers && !showNotes && !showHashtags && !showLinks) {
                    // The query matched something, just not in the open tab;
                    // a blank screen there reads as a bug.
                    item(key = "empty-filter") {
                        Column(
                            horizontalAlignment = Alignment.CenterHorizontally,
                            modifier = Modifier
                                .fillMaxWidth()
                                .padding(horizontal = 24.dp, vertical = 40.dp),
                        ) {
                            Text(
                                "No ${resultFilter.displayName.lowercase()} matched \u201C${query.trim()}\u201D",
                                color = SecondaryText,
                                fontSize = 14.sp,
                                fontWeight = FontWeight.SemiBold,
                                textAlign = TextAlign.Center,
                            )
                            Spacer(Modifier.height(6.dp))
                            Text("Other tabs have results.", color = TertiaryText, fontSize = 12.sp)
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
