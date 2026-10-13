package com.nostrvault.ui.screens.dashboard

import android.util.Log
import androidx.compose.foundation.gestures.animateScrollBy
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.material3.*
import androidx.compose.material3.pulltorefresh.PullToRefreshBox
import androidx.compose.runtime.*
import com.nostrvault.tutorials.TutorialContent
import com.nostrvault.tutorials.tutorialAnchor
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.semantics.selected
import com.nostrvault.ui.components.rememberFilterNoteState
import com.nostrvault.ui.components.countNote
import com.nostrvault.ui.components.VaultRightPill
import com.nostrvault.ui.components.FilterNote
import kotlinx.coroutines.launch
import kotlinx.coroutines.delay
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.foundation.layout.offset
import androidx.compose.foundation.layout.RowScope
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.hilt.navigation.compose.hiltViewModel
import com.nostrvault.ui.navigation.FloatingButtonRow
import com.nostrvault.ui.navigation.FloatingButtonRow.floatingRowButton
import com.nostrvault.data.model.*
import com.nostrvault.ui.components.CustomZapSheet
import com.nostrvault.ui.components.GlassScaffold
import com.nostrvault.ui.components.ScrollCondenseEffect
import com.nostrvault.ui.components.blockedWhen
import com.nostrvault.ui.components.chromeFab
import com.nostrvault.ui.components.rememberChromeFolded
import com.nostrvault.ui.navigation.NotificationTarget
import com.nostrvault.ui.navigation.RelayFocus
import com.nostrvault.ui.navigation.Screen
import com.nostrvault.ui.navigation.TabReselect
import com.nostrvault.ui.theme.*
import kotlinx.coroutines.*
import kotlinx.coroutines.flow.collectLatest
import kotlinx.coroutines.flow.filterNotNull
import kotlinx.serialization.json.*
import com.nostrvault.ui.screens.VaultModePill
import com.nostrvault.ui.components.RevealNewestEffect

/** One filter in the relay half's right pill, for the note its tap leaves. iOS `VaultFilterChoice`. */
internal data class RelayFilterChoice(
    val icon: ImageVector,
    val name: String,
    val empty: String,
    /** Notes, Likes and Zaps rebuild their list after a pick; the note waits for it. */
    val waitsForList: Boolean = true,
)

/**
 * The trailing pill's filters for [viewMode], as bare icons. Notes: All · Mine ·
 * Mentions · Outside. Likes and Zaps: Received · Given. Followers: New · All.
 * [onPicked] gets each tap, and whether it changed the list.
 */
@Composable
private fun RowScope.RelayFilters(
    viewMode: VaultViewMode,
    contentFilter: VaultContentFilter,
    likesFilter: VaultLikesFilter,
    zapsFilter: VaultZapsFilter,
    followersFilter: VaultFollowersFilter,
    noteScope: VaultNoteScope,
    recipesOnly: Boolean,
    viewModel: DashboardViewModel,
    onPicked: (RelayFilterChoice, changed: Boolean) -> Unit,
) {
    val things = noteScope.name.lowercase()
    @Composable
    fun filter(choice: RelayFilterChoice, tooltip: String, selected: Boolean, onClick: () -> Unit) =
        IconFilterButton(
            icon = choice.icon,
            contentDescription = tooltip,
            isSelected = selected,
            onClick = {
                onClick()
                onPicked(choice, !selected)
            },
        )
    when (viewMode) {
        VaultViewMode.NOTES -> {
            filter(RelayFilterChoice(NostrVaultIcons.Layers, "All $things", "No $things yet"), "All", contentFilter == VaultContentFilter.ALL) {
                viewModel.setContentFilter(VaultContentFilter.ALL)
            }
            filter(RelayFilterChoice(NostrVaultIcons.Profile, "Your $things", "None of your $things yet"), "Mine", contentFilter == VaultContentFilter.MINE) {
                viewModel.setContentFilter(VaultContentFilter.MINE)
            }
            filter(RelayFilterChoice(NostrVaultIcons.At, "Mentions", "No mentions yet"), "Mentions", contentFilter == VaultContentFilter.TAGGED) {
                viewModel.setContentFilter(VaultContentFilter.TAGGED)
            }
            filter(RelayFilterChoice(NostrVaultIcons.OutsideNetwork, "From outside your network", "No replies from outside"), "Replies from outside your network", contentFilter == VaultContentFilter.OUTSIDE) {
                viewModel.setContentFilter(VaultContentFilter.OUTSIDE)
            }
            // Articles only: just the recipes (zapcooking / nostrcooking tags).
            if (noteScope == VaultNoteScope.ARTICLES) {
                val recipes = RelayFilterChoice(NostrVaultIcons.Recipes, "Recipes", "No recipes yet")
                IconFilterButton(
                    icon = recipes.icon,
                    contentDescription = "Recipes only",
                    isSelected = recipesOnly,
                    onClick = {
                        viewModel.toggleRecipesOnly()
                        // Turning it off says so; turning it on counts.
                        onPicked(if (recipesOnly) recipes.copy(waitsForList = false, name = "") else recipes, true)
                    },
                )
            }
        }
        VaultViewMode.LIKES -> {
            filter(RelayFilterChoice(NostrVaultIcons.Received, "Likes received", "No likes yet"), "Received", likesFilter == VaultLikesFilter.ON_MY_NOTES) {
                viewModel.setLikesFilter(VaultLikesFilter.ON_MY_NOTES)
            }
            filter(RelayFilterChoice(NostrVaultIcons.Given, "Likes given", "No likes given yet"), "Given", likesFilter == VaultLikesFilter.MY_LIKES) {
                viewModel.setLikesFilter(VaultLikesFilter.MY_LIKES)
            }
        }
        VaultViewMode.ZAPS -> {
            filter(RelayFilterChoice(NostrVaultIcons.Received, "Zaps received", "No zaps yet"), "Received", zapsFilter == VaultZapsFilter.ON_MY_NOTES) {
                viewModel.setZapsFilter(VaultZapsFilter.ON_MY_NOTES)
            }
            filter(RelayFilterChoice(NostrVaultIcons.Given, "Zaps given", "No zaps given yet"), "Given", zapsFilter == VaultZapsFilter.MY_ZAPS) {
                viewModel.setZapsFilter(VaultZapsFilter.MY_ZAPS)
            }
        }
        VaultViewMode.FOLLOWERS -> {
            filter(RelayFilterChoice(NostrVaultIcons.Discover, "Newest followers", "No followers yet", waitsForList = false), "New", followersFilter == VaultFollowersFilter.NEW) {
                viewModel.setFollowersFilter(VaultFollowersFilter.NEW)
            }
            filter(RelayFilterChoice(NostrVaultIcons.Groups, "All followers", "No followers yet", waitsForList = false), "All", followersFilter == VaultFollowersFilter.ALL) {
                viewModel.setFollowersFilter(VaultFollowersFilter.ALL)
            }
        }
    }
}

// ═══════════════════════════════════════════════════════════════════
// DashboardScreen composable
// ═══════════════════════════════════════════════════════════════════

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun DashboardScreen(
    onNoteClick: (String) -> Unit,
    /** Where a quoted long-form post opens; the note screen shows Markdown source. */
    onArticleClick: (String) -> Unit,
    onProfileClick: (String) -> Unit,
    feedService: com.nostrvault.service.FeedService,
    /** The Vault Dashboard, which the Vault tab presents over either half. */
    onOpenDashboard: () -> Unit,
    viewModel: DashboardViewModel = hiltViewModel(),
) {
    // Mode & filters
    val viewMode by viewModel.viewMode.collectAsState()
    val noteScope by viewModel.noteScope.collectAsState()
    val recipesOnly by viewModel.recipesOnly.collectAsState()
    val newModes by viewModel.newModes.collectAsState()
    // In Zaps Only mode the Likes tab is hidden — route a stuck selection back to Notes.
    val zapsOnly = LocalZapsOnlyMode.current
    LaunchedEffect(zapsOnly, viewMode) {
        if (zapsOnly && viewMode == VaultViewMode.LIKES) {
            viewModel.selectMode(VaultMode.NOTES)
        }
    }
    val contentFilter by viewModel.contentFilter.collectAsState()
    val likesFilter by viewModel.likesFilter.collectAsState()
    val zapsFilter by viewModel.zapsFilter.collectAsState()
    val followersFilter by viewModel.followersFilter.collectAsState()
    val followerSnapshot by viewModel.followerSnapshot.collectAsState()

    // Display data
    val displayNotes by viewModel.displayNotes.collectAsState()
    val displayLikedNotes by viewModel.displayLikedNotes.collectAsState()
    val displayZappedNotes by viewModel.displayZappedNotes.collectAsState()

    // Quoted events for the cards below. This tab never asked for them at all,
    // so a quote here was dropped twice over: never fetched, and never drawn.
    val quotedNotes by feedService.quotedNotes.collectAsState()
    LaunchedEffect(displayNotes, displayLikedNotes, displayZappedNotes) {
        val ids = (displayNotes + displayLikedNotes + displayZappedNotes)
            .flatMap { it.quotedEventIds }
            .distinct()
        if (ids.isNotEmpty()) feedService.fetchMissingQuotedNotes(ids)
    }
    LaunchedEffect(displayNotes, displayLikedNotes, displayZappedNotes, quotedNotes) {
        val ids = (displayNotes + displayLikedNotes + displayZappedNotes)
            .flatMap { it.quotedEventIds }
            .distinct()
        if (ids.isNotEmpty()) feedService.fetchMissingQuotedProfiles(ids)
    }
    val reactionMap by viewModel.reactionMap.collectAsState()
    val zapMap by viewModel.zapMap.collectAsState()
    val repostMap by viewModel.repostMap.collectAsState()
    val quoteMap by viewModel.quoteMap.collectAsState()
    val notesHasLoadedOnce by viewModel.notesHasLoadedOnce.collectAsState()
    val likesHasLoadedOnce by viewModel.likesHasLoadedOnce.collectAsState()
    val zapsHasLoadedOnce by viewModel.zapsHasLoadedOnce.collectAsState()
    val walletGivenLoading by viewModel.walletGivenLoading.collectAsState()

    // Connection / loading
    val isRefreshing by viewModel.isRefreshing.collectAsState()
    val isLoadingMore by viewModel.isLoadingMore.collectAsState()
    val isLoadingOlder by viewModel.isLoadingOlder.collectAsState()
    val noOlderPages by viewModel.noOlderPages.collectAsState()
    val connectionColor by viewModel.connectionColor.collectAsState()
    val allProfiles by viewModel.profiles.collectAsState()
    val listState = rememberLazyListState()
    val context = LocalContext.current
    val colors = LocalNostrVaultColors.current

    // A tapped notification parks its event in RelayFocus (see NavGraph). Pick
    // the list that holds it, wait for it to load, scroll it to the middle and
    // outline it for 3 s — iOS consumeRelayFocus. If it never shows (older
    // than the loaded page), open the post instead, so a tap always lands.
    var focusedEventId by remember { mutableStateOf<String?>(null) }
    val currentZapsOnly by rememberUpdatedState(zapsOnly)
    val currentOnNoteClick by rememberUpdatedState(onNoteClick)
    LaunchedEffect(Unit) {
        RelayFocus.pending.filterNotNull().collectLatest {
            val request = RelayFocus.consume() ?: return@collectLatest
            focusedEventId = null
            viewModel.applyRelayFocusView(request, currentZapsOnly)
            if (request.type == NotificationTarget.FOLLOWERS) return@collectLatest
            // The feed dashboard opens a list, not a post: nothing to find.
            if (request.eventId.isEmpty()) return@collectLatest
            // The event can still be arriving from the relay and the lists
            // rebuild on a debounce, so look for up to ~10 s.
            // Once, when the event's kind is first known; after that a pick
            // from the pill is yours to keep.
            var aligned = false
            repeat(40) {
                if (!aligned) aligned = viewModel.alignFocusScope(request, currentZapsOnly)
                val id = viewModel.focusCandidates(request).firstOrNull { candidate ->
                    focusShownNotes(viewModel).any { it.id == candidate }
                }
                if (id != null) {
                    delay(150) // let the list lay the row out
                    val index = focusShownNotes(viewModel).indexOfFirst { it.id == id }
                    if (index >= 0) {
                        listState.animateScrollToItem(index)
                        val layout = listState.layoutInfo
                        layout.visibleItemsInfo.firstOrNull { it.key == id }?.let { item ->
                            val center = (layout.viewportStartOffset + layout.viewportEndOffset) / 2
                            listState.animateScrollBy((item.offset + item.size / 2 - center).toFloat())
                        }
                        focusedEventId = id
                        delay(3_000)
                        focusedEventId = null
                        return@collectLatest
                    }
                }
                delay(250)
            }
            viewModel.focusFallbackNoteId(request)?.let { currentOnNoteClick(it) }
        }
    }

    // Zap sheet state
    var zapNoteId by remember { mutableStateOf<String?>(null) }
    val zapSheetState = rememberModalBottomSheetState(skipPartiallyExpanded = true)

    // Trigger load-more when near bottom
    val shouldLoadMore by remember {
        derivedStateOf {
            val lastVisible = listState.layoutInfo.visibleItemsInfo.lastOrNull()?.index ?: 0
            val total = listState.layoutInfo.totalItemsCount
            val result = lastVisible >= total - 5
            result
        }
    }
    // Articles and Highlights are short: their end is always in sight, so
    // they page with a button rather than on sight (iOS sparseNotesScope).
    val pagesByButton = viewMode == VaultViewMode.NOTES && noteScope.pagesByButton
    LaunchedEffect(shouldLoadMore, isRefreshing, pagesByButton) {
        android.util.Log.d("DashboardScreen", "shouldLoadMore=$shouldLoadMore, isRefreshing=$isRefreshing, items=${listState.layoutInfo.totalItemsCount}")
        if (shouldLoadMore && !isRefreshing && !pagesByButton) {
            android.util.Log.d("DashboardScreen", "Triggering loadMore()")
            viewModel.loadMore()
        }
    }

    // The Vault button carries the relay health colour.
    val dotColor = connectionDotColor(connectionColor)

    // Where the list is relative to its top: the chrome always shows near it.
    ScrollCondenseEffect(
        scrollKey = listState,
        firstVisibleItemIndex = { listState.firstVisibleItemIndex },
        firstVisibleItemScrollOffset = { listState.firstVisibleItemScrollOffset },
    )

    // Tapping the Vault tab again goes to the top of the list (iOS #275).
    LaunchedEffect(Unit) {
        TabReselect.of(Screen.Dashboard).collect { listState.animateScrollToItem(0) }
    }
    // New notes, likes or zaps landing above the top row show, as on "Vault".
    RevealNewestEffect(listState) {
        when (viewMode) {
            VaultViewMode.NOTES -> displayNotes.map { it.id }
            VaultViewMode.LIKES -> displayLikedNotes.map { it.id }
            VaultViewMode.ZAPS -> displayZappedNotes.map { it.id }
            VaultViewMode.FOLLOWERS -> emptyList()
        }
    }

    // The line under the bar after a filter tap. A list rebuilt after the
    // pick is counted when it lands; "checking…" shows only if that takes a
    // moment.
    val filterNote = rememberFilterNoteState()
    val noteCoroutines = rememberCoroutineScope()
    var pendingFilter by remember { mutableStateOf<RelayFilterChoice?>(null) }
    fun showCount(choice: RelayFilterChoice) {
        val (count, capped) = when (viewModel.viewMode.value) {
            VaultViewMode.NOTES -> viewModel.displayNotes.value.size.let { it to (it >= viewModel.pageSize) }
            VaultViewMode.LIKES -> viewModel.displayLikedNotes.value.size.let { it to (it >= viewModel.pageSize) }
            VaultViewMode.ZAPS -> viewModel.displayZappedNotes.value.size.let { it to (it >= viewModel.pageSize) }
            VaultViewMode.FOLLOWERS ->
                (viewModel.followerSnapshot.value?.entries(viewModel.followersFilter.value)?.size ?: 0) to false
        }
        filterNote.show(countNote(choice.icon, choice.name, count, capped, choice.empty))
    }
    val displayPass by viewModel.displayPass.collectAsState()
    LaunchedEffect(displayPass) {
        pendingFilter?.let { pendingFilter = null; showCount(it) }
    }
    LaunchedEffect(viewMode) { pendingFilter = null }
    val onFilterPicked: (RelayFilterChoice, Boolean) -> Unit = { choice, changed ->
        when {
            choice.name.isEmpty() -> { pendingFilter = null; filterNote.show(FilterNote.off("Recipes")) }
            changed && choice.waitsForList -> {
                pendingFilter = choice
                noteCoroutines.launch {
                    delay(400)
                    if (pendingFilter == choice) filterNote.show(FilterNote(choice.icon, "${choice.name} · checking…"))
                }
            }
            else -> { pendingFilter = null; showCount(choice) }
        }
    }

    GlassScaffold(
        toolbar = {
            Box {
                Row(
                    verticalAlignment = Alignment.CenterVertically,
                    modifier = Modifier
                        .fillMaxWidth()
                        .statusBarsPadding()
                        .padding(horizontal = 12.dp, vertical = 8.dp),
                ) {
                    // Leading: the Vault pill, the mode switcher (iOS VaultModePill).
                    VaultModePill(
                        mode = VaultMode.of(showsMedia = false, viewMode = viewMode, scope = noteScope),
                        zapsOnly = zapsOnly,
                        newModes = newModes,
                        onSelect = viewModel::selectMode,
                        onOpenDashboard = onOpenDashboard,
                        modifier = Modifier.tutorialAnchor(TutorialContent.VAULT_MODES),
                    )

                    Spacer(Modifier.width(8.dp))

                    // Trailing pill: Messages, a line, then the current mode's
                    // filters as bare icons. Each icon means one thing in every
                    // mode (tray in = others gave you, tray out = you gave); a tap
                    // says what it picked in the note under the bar.
                    Box(Modifier.weight(1f), contentAlignment = Alignment.CenterEnd) {
                        VaultRightPill {
                            RelayFilters(viewMode, contentFilter, likesFilter, zapsFilter, followersFilter, noteScope, recipesOnly, viewModel, onPicked = onFilterPicked)
                        }
                    }
                }
            }
        },
        floatingActionButton = {
            // The FAB folds with the bars, following the finger.
            val folded by rememberChromeFolded()
            Box(Modifier.chromeFab().blockedWhen(folded)) {
                Surface(
                    onClick = onOpenDashboard,
                    modifier = Modifier
                        .floatingRowButton()
                        .tutorialAnchor(TutorialContent.VAULT_RELAY),
                    color = dotColor,
                    shape = CircleShape,
                    shadowElevation = 8.dp,
                ) {
                    Row(
                        verticalAlignment = Alignment.CenterVertically,
                        modifier = Modifier
                            .height(FloatingButtonRow.buttonHeight)
                            .padding(horizontal = 18.dp),
                    ) {
                        Icon(
                            imageVector = NostrVaultIcons.TabVault,
                            contentDescription = null,
                            tint = PrimaryText,
                            modifier = Modifier.size(18.dp),
                        )
                        Spacer(Modifier.width(6.dp))
                        Text(
                            text = "Vault",
                            color = PrimaryText,
                            fontSize = 14.sp,
                            fontWeight = FontWeight.Bold,
                        )
                    }
                }
            }
        },
    ) { padding ->
        // Whatever the visible notes quote. The relay tab strips the nostr:
        // reference out of the body text and drew nothing in its place, so a
        // quoted note or article left no trace here at all — the feed and
        // thread screens already resolve theirs this way.
        val visibleNotes = when (viewMode) {
            VaultViewMode.NOTES -> displayNotes
            VaultViewMode.LIKES -> displayLikedNotes
            VaultViewMode.ZAPS -> displayZappedNotes
            VaultViewMode.FOLLOWERS -> emptyList()
        }
        val quotedIds = remember(visibleNotes) {
            visibleNotes.flatMap { it.quotedEventIds }.distinct()
        }
        LaunchedEffect(quotedIds) {
            if (quotedIds.isNotEmpty()) {
                feedService.fetchMissingQuotedNotes(quotedIds)
                feedService.fetchMissingQuotedProfiles(quotedIds)
            }
        }
        val resolvedQuotes by feedService.parentNotesCache.collectAsState()
        val quotedNotes = remember(quotedIds, resolvedQuotes) {
            quotedIds.mapNotNull { id -> feedService.quotedNoteFor(id)?.let { id to it } }.toMap()
        }

        // Long-press Report Post / Block User on a row (iOS NoteRow). Reporting
        // also blocks the author, matching the feed, NoteDetail, and iOS.
        val blockAuthor: (String) -> Unit = { pubkey -> feedService.blockUser(pubkey) }
        val reportNote: (FeedNote, String, String) -> Unit = { note, reason, description ->
            viewModel.reportNote(note.id, note.pubkey, reason, description)
            feedService.blockUser(note.pubkey)
        }

        PullToRefreshBox(
            isRefreshing = isRefreshing,
            onRefresh = viewModel::loadLocalRelayNotes,
            modifier = Modifier.fillMaxSize(),
        ) {
            when (viewMode) {
                VaultViewMode.NOTES -> NotesContent(
                    notes = displayNotes,
                    scope = noteScope,
                    recipesOnly = recipesOnly,
                    loadOlder = if (pagesByButton && noteScope !in noOlderPages) viewModel::loadOlderInScope else null,
                    isLoadingOlder = isLoadingOlder,
                    quotedNotes = quotedNotes,
                    reactionMap = reactionMap,
                    zapMap = zapMap,
                    repostMap = repostMap,
                    quoteMap = quoteMap,
                    isRefreshing = isRefreshing,
                    hasLoadedOnce = notesHasLoadedOnce,
                    isLoadingMore = isLoadingMore,
                    listState = listState,
                    allProfiles = allProfiles,
                    padding = padding,
                    viewModel = viewModel,
                    onNoteClick = onNoteClick,
                    onArticleClick = onArticleClick,
                    onProfileClick = onProfileClick,
                    focusedEventId = focusedEventId,
                    onReportNote = reportNote,
                    onBlockAuthor = blockAuthor,
                )
                VaultViewMode.LIKES -> LikesContent(
                    notes = displayLikedNotes,
                    quotedNotes = quotedNotes,
                    reactionMap = reactionMap,
                    hasLoadedOnce = likesHasLoadedOnce,
                    isRefreshing = isRefreshing,
                    likesFilter = likesFilter,
                    listState = listState,
                    allProfiles = allProfiles,
                    padding = padding,
                    viewModel = viewModel,
                    onNoteClick = onNoteClick,
                    onArticleClick = onArticleClick,
                    onProfileClick = onProfileClick,
                    focusedEventId = focusedEventId,
                    onReportNote = reportNote,
                    onBlockAuthor = blockAuthor,
                )
                VaultViewMode.ZAPS -> ZapsContent(
                    notes = displayZappedNotes,
                    quotedNotes = quotedNotes,
                    zapMap = zapMap,
                    hasLoadedOnce = zapsHasLoadedOnce,
                    isRefreshing = isRefreshing,
                    zapsFilter = zapsFilter,
                    walletGivenLoading = walletGivenLoading,
                    listState = listState,
                    allProfiles = allProfiles,
                    padding = padding,
                    viewModel = viewModel,
                    onNoteClick = onNoteClick,
                    onArticleClick = onArticleClick,
                    onProfileClick = onProfileClick,
                    focusedEventId = focusedEventId,
                    onReportNote = reportNote,
                    onBlockAuthor = blockAuthor,
                )
                VaultViewMode.FOLLOWERS -> FollowersContent(
                    snapshot = followerSnapshot,
                    filter = followersFilter,
                    listState = listState,
                    allProfiles = allProfiles,
                    padding = padding,
                    onProfileClick = onProfileClick,
                )
            }
        }
    }

    // Zap sheet
    if (zapNoteId != null) {
        CustomZapSheet(
            sheetState = zapSheetState,
            defaultAmount = viewModel.configStore.config.value.defaultZapAmount,
            onDismiss = { zapNoteId = null },
            onZap = { _ -> zapNoteId = null },
        )
    }
}

/** The local relay connection's colour, for the Vault button. */
internal fun connectionDotColor(connectionColor: String): androidx.compose.ui.graphics.Color = when (connectionColor) {
    "green" -> SuccessGreen
    "yellow", "orange" -> ZapOrange
    "red" -> ErrorRed
    else -> SecondaryText
}

/** The list on screen for the current view mode. */
private fun focusShownNotes(viewModel: DashboardViewModel): List<FeedNote> =
    when (viewModel.viewMode.value) {
        VaultViewMode.NOTES -> viewModel.displayNotes.value
        VaultViewMode.LIKES -> viewModel.displayLikedNotes.value
        VaultViewMode.ZAPS -> viewModel.displayZappedNotes.value
        VaultViewMode.FOLLOWERS -> emptyList()
    }
