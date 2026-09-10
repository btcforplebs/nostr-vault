package com.nostrvault.ui.screens.feed

import android.content.Intent
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.*
import androidx.compose.material3.pulltorefresh.PullToRefreshBox
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.shadow
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.compose.ui.zIndex
import androidx.hilt.navigation.compose.hiltViewModel
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import com.nostrvault.data.model.FeedMode
import com.nostrvault.data.model.PopularFilter
import com.nostrvault.ui.components.CustomZapSheet
import com.nostrvault.ui.components.BroadcastSheet
import com.nostrvault.ui.components.EmojiPickerSheet
import com.nostrvault.ui.components.CompactNoteCard
import com.nostrvault.ui.components.GlassPill
import com.nostrvault.ui.components.GlassScaffold
import com.nostrvault.ui.components.NoteCard
import com.nostrvault.ui.components.SkeletonFeed
import com.nostrvault.service.ScrollPosition
import com.nostrvault.ui.theme.*

/**
 * Main feed screen with mode tabs, pull-to-refresh, and infinite scroll.
 * Port of FeedView.swift.
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun FeedScreen(
    onNoteClick: (String) -> Unit,
    onProfileClick: (String) -> Unit,
    onCompose: () -> Unit,
    onReply: ((String) -> Unit)? = null,
    onQuote: ((String) -> Unit)? = null,
    onNavigateToSettings: () -> Unit,
    onNavigateToDashboard: () -> Unit,
    viewModel: FeedViewModel = hiltViewModel(),
) {
    val feedMode by viewModel.feedMode.collectAsState()
    val notes by viewModel.filteredNotes.collectAsState()
    val isRefreshing by viewModel.isRefreshing.collectAsState()
    val isLoadingMore by viewModel.isLoadingMore.collectAsState()
    val connectionStatus by viewModel.connectionStatus.collectAsState()
    val connectionColor by viewModel.connectionColor.collectAsState()
    val allProfiles by viewModel.profiles.collectAsState()
    val isCompact by viewModel.compactModeEnabled.collectAsState()
    val autoLoad by viewModel.autoLoadEnabled.collectAsState()
    val showReposts by viewModel.showReposts.collectAsState()
    val showReplies by viewModel.showReplies.collectAsState()
    val mediaFollowingOnly by viewModel.mediaFollowingOnly.collectAsState()
    val popularFilter by viewModel.popularFilter.collectAsState()
    val showEngagementStats by viewModel.showEngagementStats.collectAsState()
    val pendingCount by viewModel.pendingNoteCount.collectAsState()
    val parentNotes by viewModel.parentNotesCache.collectAsState()
    val parentIsNext by viewModel.parentIsNextNote.collectAsState()
    val quotedNotes by viewModel.quotedNotesCache.collectAsState()
    val listState = rememberLazyListState()
    val context = LocalContext.current
    val scope = rememberCoroutineScope()

    // Inline expansion state for compact mode (iOS parity: tap expands inline first)
    var expandedNoteId by remember { mutableStateOf<String?>(null) }

    // Reset expanded note when feed mode changes or compact mode is toggled off
    LaunchedEffect(feedMode, isCompact) {
        expandedNoteId = null
    }

    // Zap sheet state
    var zapNoteId by remember { mutableStateOf<String?>(null) }
    val zapSheetState = rememberModalBottomSheetState(skipPartiallyExpanded = true)

    // More menu / delete confirmation state
    var deleteNoteId by remember { mutableStateOf<String?>(null) }
    var moreMenuNoteId by remember { mutableStateOf<String?>(null) }

    // Emoji picker state
    var emojiPickerNoteId by remember { mutableStateOf<String?>(null) }
    val emojiSheetState = rememberModalBottomSheetState(skipPartiallyExpanded = true)

    // Broadcast sheet state
    var broadcastNoteId by remember { mutableStateOf<String?>(null) }
    val broadcastSheetState = rememberModalBottomSheetState(skipPartiallyExpanded = true)

    // Feed config sheet state
    var showFeedConfig by remember { mutableStateOf(false) }

    // Trigger load-more when near bottom
    val shouldLoadMore by remember {
        derivedStateOf {
            val lastVisible = listState.layoutInfo.visibleItemsInfo.lastOrNull()?.index ?: 0
            lastVisible >= listState.layoutInfo.totalItemsCount - 5
        }
    }
    LaunchedEffect(shouldLoadMore) {
        if (shouldLoadMore && notes.isNotEmpty()) viewModel.loadMore()
    }

    // Track whether the user is at the top of the feed
    val isAtTop by remember {
        derivedStateOf {
            listState.firstVisibleItemIndex == 0 && listState.firstVisibleItemScrollOffset < 50
        }
    }

    // Save scroll position for snapshot persistence (debounced on scroll stop)
    LaunchedEffect(listState.isScrollInProgress) {
        if (!listState.isScrollInProgress) {
            viewModel.saveScrollPosition(
                listState.firstVisibleItemIndex,
                listState.firstVisibleItemScrollOffset,
            )
        }
    }

    // Restore scroll position from disk snapshot on cold boot
    val restoredPosition by viewModel.restoredScrollPosition.collectAsState()
    LaunchedEffect(restoredPosition, notes) {
        val pos = restoredPosition ?: return@LaunchedEffect
        if (notes.isNotEmpty() && pos.index < notes.size) {
            listState.scrollToItem(pos.index, pos.offset)
            viewModel.clearRestoredPosition()
        }
    }

    // Auto-apply pending notes when at top with auto-load enabled.
    // Uses snapshotFlow so that rapid pendingCount changes don't restart
    // the effect (unlike LaunchedEffect with pendingCount as a key).
    LaunchedEffect(Unit) {
        snapshotFlow { pendingCount > 0 && autoLoad && isAtTop }
            .collect { shouldApply ->
                if (shouldApply) {
                    // Brief debounce to batch rapid arrivals
                    delay(150)
                    // Re-check — user may have scrolled away during debounce
                    if (isAtTop) {
                        viewModel.applyPendingNotes()
                        // Keyed LazyColumn keeps the old first item in view
                        // after a prepend — snap back to show the new notes.
                        listState.scrollToItem(0)
                    }
                }
            }
    }

    // Handle tab re-selection: scroll to top or refresh if already at top
    LaunchedEffect(Unit) {
        viewModel.scrollToTopRequest.collect {
            if (isAtTop) {
                viewModel.refresh()
            } else {
                listState.scrollToItem(0) // Instant scroll for better performance
            }
        }
    }

    GlassScaffold(
        toolbar = {
            FeedTopBar(
                feedMode = feedMode,
                connectionStatus = connectionStatus,
                connectionColor = connectionColor,
                isCompact = isCompact,
                autoLoad = autoLoad,
                showReposts = showReposts,
                showReplies = showReplies,
                mediaFollowingOnly = mediaFollowingOnly,
                popularFilter = popularFilter,
                showEngagementStats = showEngagementStats,
                onModeChange = viewModel::setFeedMode,
                onToggleCompact = viewModel::toggleCompactMode,
                onToggleAutoLoad = viewModel::toggleAutoLoad,
                onToggleReposts = viewModel::toggleShowReposts,
                onToggleReplies = viewModel::toggleShowReplies,
                onToggleMediaFollowing = viewModel::toggleMediaFollowing,
                onSetPopularFilter = viewModel::setPopularFilter,
                onToggleEngagementStats = viewModel::toggleShowEngagementStats,
                onOpenFeedDashboard = { showFeedConfig = true },
            )
        },
        floatingActionButton = {
            FloatingActionButton(
                onClick = onCompose,
                modifier = Modifier.padding(bottom = 88.dp),
                containerColor = LocalNostrVaultColors.current.primary,
                contentColor = PrimaryText,
            ) {
                Icon(NostrVaultIcons.Create, contentDescription = "Compose")
            }
        },
    ) { padding ->
        Box(modifier = Modifier.fillMaxSize()) {
        PullToRefreshBox(
            isRefreshing = isRefreshing,
            onRefresh = viewModel::refresh,
            modifier = Modifier.fillMaxSize(),
        ) {
            if (notes.isEmpty() && isRefreshing) {
                // Shimmer skeleton loading
                SkeletonFeed(count = 5)
            } else if (notes.isEmpty()) {
                EmptyFeedPlaceholder(feedMode)
            } else {
                LazyColumn(
                    state = listState,
                    contentPadding = PaddingValues(
                        top = padding.calculateTopPadding(),
                        bottom = padding.calculateBottomPadding() + 88.dp,
                    ),
                    modifier = Modifier.fillMaxSize(),
                ) {
                    items(
                        items = notes,
                        key = { it.id },
                        contentType = { note ->
                            if (isCompact && expandedNoteId != note.id) "compact" else "full"
                        }
                    ) { note ->
                        val isExpanded = isCompact && expandedNoteId == note.id
                        val showCompact = isCompact && !isExpanded

                        // Cache profile lookups to avoid redundant map reads during recomposition
                        val noteProfile = remember(note.id, note.pubkey) {
                            viewModel.profileFor(note.pubkey)
                        }
                        val repostedByProfile = remember(note.id, note.repostedBy) {
                            note.repostedBy?.let { viewModel.profileFor(it) }
                        }

                        // Remove expensive Crossfade animation for better scroll performance
                        if (showCompact) {
                            CompactNoteCard(
                                note = note,
                                profile = noteProfile,
                                repostedByProfile = repostedByProfile,
                                onNoteClick = { id ->
                                    // Expand inline first instead of navigating
                                    expandedNoteId = id
                                },
                                onProfileClick = onProfileClick,
                                modifier = Modifier.padding(horizontal = 10.dp, vertical = 2.dp),
                            )
                        } else {
                            val replyToProfile = remember(note.id, note.replyToPubkey) {
                                note.replyToPubkey?.let { viewModel.profileFor(it) }
                            }

                            // Fetch parent note if this is a reply and parent isn't cached
                            // Move outside of LaunchedEffect for better performance
                            val parentEventId = note.parentEventId
                            if (parentEventId != null) {
                                LaunchedEffect(note.id, parentEventId) {
                                    if (viewModel.parentNoteFor(parentEventId) == null) {
                                        viewModel.fetchMissingParentNote(parentEventId)
                                    }
                                }
                            }

                            if (note.quotedEventIds.isNotEmpty()) {
                                LaunchedEffect(note.id) {
                                    note.quotedEventIds.forEach { qid ->
                                        if (viewModel.quotedNoteFor(qid) == null) {
                                            viewModel.fetchMissingQuotedNote(qid)
                                        }
                                    }
                                }
                            }

                            val parentNote = parentEventId?.let { viewModel.parentNoteFor(it) }
                            val isParentNext = parentEventId?.let { viewModel.isParentNext(note.id) } ?: false

                            NoteCard(
                                note = note,
                                profile = noteProfile,
                                stats = viewModel.statsFor(note.id),
                                profiles = allProfiles,
                                isLiked = viewModel.isLiked(note.id),
                                isZapped = viewModel.isZapped(note.id),
                                repostedByProfile = repostedByProfile,
                                replyToProfile = replyToProfile,
                                parentNote = parentNote,
                                parentIsNext = isParentNext,
                                quotedNotes = quotedNotes,
                                onNoteClick = onNoteClick,
                                onProfileClick = onProfileClick,
                                onLike = viewModel::likeNote,
                                onRepost = viewModel::repostNote,
                                onZap = { id -> zapNoteId = id },
                                onReply = onReply ?: { _ -> onCompose() },
                                onShare = { id ->
                                    val shareNote = notes.find { it.id == id }
                                    val shareText = shareNote?.content ?: "nostr:${id}"
                                    val intent = Intent(Intent.ACTION_SEND).apply {
                                        type = "text/plain"
                                        putExtra(Intent.EXTRA_TEXT, shareText)
                                    }
                                    context.startActivity(Intent.createChooser(intent, "Share Note"))
                                },
                                onMore = { id -> moreMenuNoteId = id },
                                onLongPressLike = { id -> emojiPickerNoteId = id },
                                modifier = Modifier.padding(horizontal = 10.dp, vertical = 4.dp),
                            )
                        }
                    }

                    if (isLoadingMore) {
                        item {
                            Box(
                                contentAlignment = Alignment.Center,
                                modifier = Modifier
                                    .fillMaxWidth()
                                    .padding(16.dp),
                            ) {
                                CircularProgressIndicator(
                                    color = LocalNostrVaultColors.current.primary,
                                    modifier = Modifier.size(24.dp),
                                )
                            }
                        }
                    }
                }
            }
        }

            // Floating "New Posts" pill
            // Remove AnimatedVisibility for better performance
            if (pendingCount > 0 && (!autoLoad || !isAtTop)) {
                NewPostsPill(
                    count = pendingCount,
                    onClick = {
                        viewModel.applyPendingNotes()
                        scope.launch { listState.scrollToItem(0) } // Instant scroll for better performance
                    },
                    modifier = Modifier
                        .align(Alignment.TopCenter)
                        .padding(top = padding.calculateTopPadding() + 12.dp)
                        .zIndex(1f)
                )
            }
        }
    }

    // Custom zap sheet
    if (zapNoteId != null) {
        CustomZapSheet(
            sheetState = zapSheetState,
            onDismiss = { zapNoteId = null },
            onZap = { amount ->
                zapNoteId?.let { viewModel.zapNote(it, amount) }
                zapNoteId = null
            },
        )
    }

    // More menu dropdown
    if (moreMenuNoteId != null) {
        val targetNote = notes.find { it.id == moreMenuNoteId }
        val isOwn = targetNote != null && viewModel.isOwnNote(targetNote.pubkey)

        AlertDialog(
            onDismissRequest = { moreMenuNoteId = null },
            title = { Text("Actions") },
            text = {
                Column {
                    // Quote
                    if (onQuote != null) {
                        TextButton(
                            onClick = {
                                moreMenuNoteId?.let { onQuote(it) }
                                moreMenuNoteId = null
                            },
                            modifier = Modifier.fillMaxWidth(),
                        ) {
                            Row(
                                verticalAlignment = Alignment.CenterVertically,
                                modifier = Modifier.fillMaxWidth(),
                            ) {
                                Icon(NostrVaultIcons.Quote, contentDescription = null, modifier = Modifier.size(18.dp))
                                Spacer(Modifier.width(8.dp))
                                Text("Quote Post")
                            }
                        }
                    }

                    // Broadcast
                    TextButton(
                        onClick = {
                            broadcastNoteId = moreMenuNoteId
                            moreMenuNoteId = null
                        },
                        modifier = Modifier.fillMaxWidth(),
                    ) {
                        Row(
                            verticalAlignment = Alignment.CenterVertically,
                            modifier = Modifier.fillMaxWidth(),
                        ) {
                            Icon(NostrVaultIcons.Send, contentDescription = null, modifier = Modifier.size(18.dp))
                            Spacer(Modifier.width(8.dp))
                            Text("Broadcast")
                        }
                    }

                    // Delete (own notes only)
                    if (isOwn) {
                        TextButton(
                            onClick = {
                                deleteNoteId = moreMenuNoteId
                                moreMenuNoteId = null
                            },
                            modifier = Modifier.fillMaxWidth(),
                        ) {
                            Row(
                                verticalAlignment = Alignment.CenterVertically,
                                modifier = Modifier.fillMaxWidth(),
                            ) {
                                Icon(NostrVaultIcons.Delete, contentDescription = null, tint = ErrorRed, modifier = Modifier.size(18.dp))
                                Spacer(Modifier.width(8.dp))
                                Text("Delete Post", color = ErrorRed)
                            }
                        }
                    }
                }
            },
            confirmButton = {
                TextButton(onClick = { moreMenuNoteId = null }) {
                    Text("Cancel")
                }
            },
        )
    }

    // Delete confirmation dialog
    if (deleteNoteId != null) {
        AlertDialog(
            onDismissRequest = { deleteNoteId = null },
            title = { Text("Delete Post") },
            text = { Text("Request deletion of this post? Not all relays honor NIP-09 deletion requests.") },
            confirmButton = {
                TextButton(onClick = {
                    deleteNoteId?.let { viewModel.deleteNote(it) }
                    deleteNoteId = null
                }) {
                    Text("Delete", color = ErrorRed)
                }
            },
            dismissButton = {
                TextButton(onClick = { deleteNoteId = null }) {
                    Text("Cancel")
                }
            },
        )
    }

    // Emoji picker sheet
    if (emojiPickerNoteId != null) {
        EmojiPickerSheet(
            sheetState = emojiSheetState,
            onDismiss = { emojiPickerNoteId = null },
            onSelectEmoji = { emoji ->
                emojiPickerNoteId?.let { viewModel.likeNote(it, emoji) }
                emojiPickerNoteId = null
            },
        )
    }

    // Broadcast sheet
    val broadcastNote = broadcastNoteId?.let { id -> notes.find { it.id == id } }
    if (broadcastNote != null) {
        BroadcastSheet(
            note = broadcastNote,
            sheetState = broadcastSheetState,
            feedService = viewModel.feedServiceRef,
            nostrService = viewModel.nostrServiceRef,
            configStore = viewModel.configStoreRef,
            onDismiss = { broadcastNoteId = null },
        )
    }

    // Feed config sheet (matches iOS feed dashboard)
    if (showFeedConfig) {
        com.nostrvault.ui.screens.dashboard.FeedConfigSheet(
            showReposts = showReposts,
            showReplies = showReplies,
            autoLoadNewNotes = autoLoad,
            feedRelays = viewModel.configStoreRef.config.value.activeFeedRelays,
            onToggleReposts = { viewModel.toggleShowReposts() },
            onToggleReplies = { viewModel.toggleShowReplies() },
            onToggleAutoLoad = { viewModel.toggleAutoLoad() },
            onManageRelays = {
                showFeedConfig = false
                onNavigateToSettings()
            },
            onDismiss = { showFeedConfig = false },
        )
    }
}

// ── Top bar ──────────────────────────────────────────────────────

@Composable
private fun FeedTopBar(
    feedMode: FeedMode,
    connectionStatus: String,
    connectionColor: String,
    isCompact: Boolean,
    autoLoad: Boolean,
    showReposts: Boolean,
    showReplies: Boolean,
    mediaFollowingOnly: Boolean,
    popularFilter: PopularFilter,
    showEngagementStats: Boolean,
    onModeChange: (FeedMode) -> Unit,
    onToggleCompact: () -> Unit,
    onToggleAutoLoad: () -> Unit,
    onToggleReposts: () -> Unit,
    onToggleReplies: () -> Unit,
    onToggleMediaFollowing: () -> Unit,
    onSetPopularFilter: (PopularFilter) -> Unit,
    onToggleEngagementStats: () -> Unit,
    onOpenFeedDashboard: () -> Unit,
) {
    val colors = LocalNostrVaultColors.current
    var feedModeExpanded by remember { mutableStateOf(false) }

    // Resolve connection dot color
    val dotColor = when (connectionColor) {
        "green" -> SuccessGreen
        "orange" -> ZapOrange
        "red" -> ErrorRed
        else -> SecondaryText
    }

    Row(
        verticalAlignment = Alignment.CenterVertically,
        modifier = Modifier
            .fillMaxWidth()
            .statusBarsPadding()
            .padding(horizontal = 12.dp, vertical = 8.dp),
    ) {
        // ── Leading pill: connection dot (clickable for dashboard) + feed mode dropdown
        GlassPill(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            // Connection status dot - clickable to open Feed Dashboard (matches iOS)
            Box(
                modifier = Modifier
                    .size(30.dp)
                    .clip(CircleShape)
                    .clickable(onClick = onOpenFeedDashboard)
                    .wrapContentSize(Alignment.Center),
            ) {
                Box(
                    modifier = Modifier
                        .size(10.dp)
                        .shadow(4.dp, CircleShape)
                        .clip(CircleShape)
                        .background(dotColor),
                )
            }

            // Feed mode dropdown
            Box {
                TextButton(
                    onClick = { feedModeExpanded = true },
                    contentPadding = PaddingValues(horizontal = 4.dp, vertical = 0.dp),
                ) {
                    Text(
                        text = feedMode.displayName,
                        color = PrimaryText,
                        fontSize = 17.sp,
                        fontWeight = FontWeight.Bold,
                    )
                    Spacer(Modifier.width(2.dp))
                    Icon(
                        imageVector = NostrVaultIcons.ChevronDown,
                        contentDescription = "Switch feed mode",
                        tint = PrimaryText,
                        modifier = Modifier.size(16.dp),
                    )
                }
                DropdownMenu(
                    expanded = feedModeExpanded,
                    onDismissRequest = { feedModeExpanded = false },
                ) {
                    FeedMode.entries.forEach { mode ->
                        DropdownMenuItem(
                            text = {
                                Text(
                                    text = mode.displayName,
                                    fontWeight = if (mode == feedMode) FontWeight.SemiBold else FontWeight.Normal,
                                )
                            },
                            leadingIcon = if (mode == feedMode) {
                                { Icon(NostrVaultIcons.Check, contentDescription = null, modifier = Modifier.size(16.dp)) }
                            } else null,
                            onClick = {
                                onModeChange(mode)
                                feedModeExpanded = false
                            },
                        )
                    }
                }
            }
        }

        Spacer(Modifier.weight(1f))

        // ── Trailing pill: compact toggle + mode-dependent filters
        GlassPill {
            // Compact view toggle (always shown)
            IconButton(onClick = onToggleCompact, modifier = Modifier.size(40.dp)) {
                Icon(
                    imageVector = if (isCompact) NostrVaultIcons.CompactView else NostrVaultIcons.ExpandedView,
                    contentDescription = if (isCompact) "Switch to expanded" else "Switch to compact",
                    tint = if (isCompact) colors.primary else SecondaryText,
                    modifier = Modifier.size(25.dp),
                )
            }

            // Mode-dependent filter buttons
            when (feedMode) {
                FeedMode.FOLLOWING, FeedMode.DISCOVERY, FeedMode.GLOBAL -> {
                    // Auto-load posts
                    IconButton(onClick = onToggleAutoLoad, modifier = Modifier.size(32.dp)) {
                        Icon(
                            imageVector = if (autoLoad) NostrVaultIcons.AutoLoad else NostrVaultIcons.AutoLoadOff,
                            contentDescription = "Auto-load",
                            tint = if (autoLoad) colors.primary else SecondaryText,
                            modifier = Modifier.size(18.dp),
                        )
                    }
                    // Show reposts
                    IconButton(onClick = onToggleReposts, modifier = Modifier.size(32.dp)) {
                        Icon(
                            imageVector = NostrVaultIcons.Repost,
                            contentDescription = "Reposts",
                            tint = if (showReposts) colors.primary else SecondaryText,
                            modifier = Modifier.size(18.dp),
                        )
                    }
                    // Show replies
                    IconButton(onClick = onToggleReplies, modifier = Modifier.size(32.dp)) {
                        Icon(
                            imageVector = NostrVaultIcons.Chat,
                            contentDescription = "Replies",
                            tint = if (showReplies) colors.primary else SecondaryText,
                            modifier = Modifier.size(18.dp),
                        )
                    }
                }
                FeedMode.MEDIA -> {
                    // Following filter
                    IconButton(onClick = onToggleMediaFollowing, modifier = Modifier.size(32.dp)) {
                        Icon(
                            imageVector = if (mediaFollowingOnly) NostrVaultIcons.People else NostrVaultIcons.PeopleOutline,
                            contentDescription = "Following",
                            tint = if (mediaFollowingOnly) colors.primary else SecondaryText,
                            modifier = Modifier.size(18.dp),
                        )
                    }
                    // Global filter
                    IconButton(onClick = onToggleMediaFollowing, modifier = Modifier.size(32.dp)) {
                        Icon(
                            imageVector = if (!mediaFollowingOnly) NostrVaultIcons.Globe else NostrVaultIcons.GlobeOutline,
                            contentDescription = "Global",
                            tint = if (!mediaFollowingOnly) colors.primary else SecondaryText,
                            modifier = Modifier.size(18.dp),
                        )
                    }
                }
                FeedMode.POPULAR -> {
                    // Follows filter
                    IconButton(
                        onClick = {
                            onSetPopularFilter(
                                if (popularFilter == PopularFilter.FOLLOWS) PopularFilter.ALL else PopularFilter.FOLLOWS
                            )
                        },
                        modifier = Modifier.size(40.dp),
                    ) {
                        Icon(
                            imageVector = if (popularFilter == PopularFilter.FOLLOWS) NostrVaultIcons.People else NostrVaultIcons.PeopleOutline,
                            contentDescription = "Follows only",
                            tint = if (popularFilter == PopularFilter.FOLLOWS) colors.primary else SecondaryText,
                            modifier = Modifier.size(18.dp),
                        )
                    }
                    // Non-follows filter
                    IconButton(
                        onClick = {
                            onSetPopularFilter(
                                if (popularFilter == PopularFilter.NON_FOLLOWS) PopularFilter.ALL else PopularFilter.NON_FOLLOWS
                            )
                        },
                        modifier = Modifier.size(40.dp),
                    ) {
                        Icon(
                            imageVector = if (popularFilter == PopularFilter.NON_FOLLOWS) NostrVaultIcons.Globe else NostrVaultIcons.GlobeOutline,
                            contentDescription = "Non-follows",
                            tint = if (popularFilter == PopularFilter.NON_FOLLOWS) colors.primary else SecondaryText,
                            modifier = Modifier.size(18.dp),
                        )
                    }
                    // Engagement stats
                    IconButton(onClick = onToggleEngagementStats, modifier = Modifier.size(32.dp)) {
                        Icon(
                            imageVector = NostrVaultIcons.BarChart,
                            contentDescription = "Engagement stats",
                            tint = if (showEngagementStats) colors.primary else SecondaryText,
                            modifier = Modifier.size(18.dp),
                        )
                    }
                }
            }
        }
    }
}

// ── Empty state ──────────────────────────────────────────────────

@Composable
private fun EmptyFeedPlaceholder(mode: FeedMode) {
    Box(
        contentAlignment = Alignment.Center,
        modifier = Modifier.fillMaxSize(),
    ) {
        Column(horizontalAlignment = Alignment.CenterHorizontally) {
            Icon(
                imageVector = NostrVaultIcons.Feed,
                contentDescription = null,
                tint = TertiaryText,
                modifier = Modifier.size(48.dp),
            )
            Spacer(Modifier.height(12.dp))
            Text(
                text = when (mode) {
                    FeedMode.FOLLOWING -> "No notes yet"
                    FeedMode.DISCOVERY -> "Discovering notes..."
                    FeedMode.GLOBAL -> "Loading global feed..."
                    FeedMode.POPULAR -> "Loading popular notes..."
                    FeedMode.MEDIA -> "No media found"
                },
                color = SecondaryText,
                fontSize = 16.sp,
            )
        }
    }
}

// ── New posts pill ──────────────────────────────────────────────

@Composable
private fun NewPostsPill(count: Int, onClick: () -> Unit, modifier: Modifier = Modifier) {
    val colors = LocalNostrVaultColors.current
    Surface(
        onClick = onClick,
        shape = RoundedCornerShape(50),
        color = colors.primary,
        shadowElevation = 8.dp,
        modifier = modifier,
    ) {
        Row(
            verticalAlignment = Alignment.CenterVertically,
            modifier = Modifier.padding(vertical = 10.dp, horizontal = 20.dp),
        ) {
            Icon(
                imageVector = NostrVaultIcons.ArrowUp,
                contentDescription = null,
                tint = PrimaryText,
                modifier = Modifier.size(14.dp),
            )
            Spacer(Modifier.width(8.dp))
            Text(
                text = "$count New Post${if (count != 1) "s" else ""}",
                fontWeight = FontWeight.Bold,
                fontSize = 13.sp,
                color = PrimaryText,
            )
        }
    }
}
