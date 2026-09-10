package com.nostrvault.ui.screens.feed

import android.content.Intent
import android.widget.Toast
import androidx.compose.animation.AnimatedVisibility
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.animation.scaleIn
import androidx.compose.animation.scaleOut
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.ExperimentalFoundationApi
import androidx.compose.foundation.combinedClickable
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.lazy.grid.GridCells
import androidx.compose.foundation.lazy.grid.GridItemSpan
import androidx.compose.foundation.lazy.grid.LazyVerticalGrid
import androidx.compose.foundation.lazy.grid.items
import androidx.compose.foundation.lazy.grid.rememberLazyGridState
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
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.compose.ui.zIndex
import androidx.hilt.navigation.compose.hiltViewModel
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import androidx.compose.ui.text.style.TextOverflow
import coil.compose.AsyncImage
import com.nostrvault.data.model.ArticleMeta
import com.nostrvault.data.model.FeedMode
import com.nostrvault.data.model.FeedProfile
import com.nostrvault.data.model.LiveStream
import com.nostrvault.data.model.FeedNote
import com.nostrvault.data.model.PopularFilter
import com.nostrvault.ui.screens.LiveStreamScreen
import com.nostrvault.ui.components.CustomZapSheet
import com.nostrvault.ui.components.FullScreenMediaRouter
import com.nostrvault.ui.components.RetryableAsyncImage
import com.nostrvault.ui.components.isVideoUrl
import com.nostrvault.ui.components.BroadcastSheet
import com.nostrvault.ui.components.EmojiPickerSheet
import com.nostrvault.ui.components.CompactNoteCard
import com.nostrvault.ui.components.GlassPill
import com.nostrvault.ui.components.GlassScaffold
import com.nostrvault.ui.components.NoteCard
import com.nostrvault.ui.components.NostrMentions
import com.nostrvault.ui.components.ScrollCondenseEffect
import com.nostrvault.ui.components.SkeletonFeed
import com.nostrvault.service.ScrollPosition
import com.nostrvault.ui.theme.*
import java.text.DateFormat

/**
 * Main feed screen with mode tabs, pull-to-refresh, and infinite scroll.
 * Port of FeedView.swift.
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun FeedScreen(
    onNoteClick: (String) -> Unit,
    onArticleClick: (String) -> Unit,
    onProfileClick: (String) -> Unit,
    onCompose: () -> Unit,
    onReply: ((String) -> Unit)? = null,
    onQuote: ((String) -> Unit)? = null,
    onNavigateToSettings: () -> Unit,
    viewModel: FeedViewModel = hiltViewModel(),
) {
    val feedMode by viewModel.feedMode.collectAsState()
    val liveStreams by viewModel.liveStreams.collectAsState()
    val liveLoading by viewModel.liveLoading.collectAsState()
    // The tapped stream is held rather than looked up again by id: a kind-30311
    // event is replaceable and short-lived, so the copy the grid was showing is
    // the one to play.
    var playingStream by remember { mutableStateOf<LiveStream?>(null) }
    val notes by viewModel.filteredNotes.collectAsState()
    val mediaNotes by viewModel.mediaNotes.collectAsState()
    val isRefreshing by viewModel.isRefreshing.collectAsState()
    val isLoadingMore by viewModel.isLoadingMore.collectAsState()
    val connectionStatus by viewModel.connectionStatus.collectAsState()
    val connectionColor by viewModel.connectionColor.collectAsState()
    // Read straight off the ViewModel's snapshot map. Collecting it here would
    // subscribe the whole screen to every metadata batch; each feed row narrows
    // its own read below instead.
    val allProfiles = viewModel.profileState
    val isCompact by viewModel.compactModeEnabled.collectAsState()
    val autoLoad by viewModel.autoLoadEnabled.collectAsState()
    val showReposts by viewModel.showReposts.collectAsState()
    val showReplies by viewModel.showReplies.collectAsState()
    val mediaFollowingOnly by viewModel.mediaFollowingOnly.collectAsState()
    val popularFilter by viewModel.popularFilter.collectAsState()
    val showEngagementStats by viewModel.showEngagementStats.collectAsState()
    val pendingCount by viewModel.pendingNoteCount.collectAsState()
    val parentNotes by viewModel.parentNotesCache.collectAsState()
    val quotedNotes by viewModel.quotedNotesCache.collectAsState()
    // Collected so the repost button re-highlights instantly after you repost.
    val repostedIds by viewModel.repostedEventIds.collectAsState()
    val parentIsNext by viewModel.parentIsNextNote.collectAsState()
    val listState = rememberLazyListState()
    val context = LocalContext.current
    val scope = rememberCoroutineScope()

    // Inline expansion state for compact mode (iOS parity: tap expands inline first)
    var expandedNoteId by remember { mutableStateOf<String?>(null) }

    // Reset expanded note when feed mode changes or compact mode is toggled off
    LaunchedEffect(feedMode, isCompact) {
        expandedNoteId = null
    }

    // Batch-fetch all missing parent notes whenever the visible notes list changes.
    // One REQ with all IDs instead of one REQ per item.
    LaunchedEffect(notes) {
        val missingIds = notes.mapNotNull { note ->
            note.parentEventId?.takeIf { viewModel.parentNoteFor(it) == null }
        }.distinct()
        if (missingIds.isNotEmpty()) {
            viewModel.fetchMissingParentNotes(missingIds)
        }
    }

    // Batch-fetch any embedded quoted notes (nostr:note1.../nevent1...) referenced
    // by the visible notes. Decoded to hex and fetched via the same path as parents.
    LaunchedEffect(notes) {
        val quotedIds = notes.flatMap { it.quotedEventIds }.distinct()
        if (quotedIds.isNotEmpty()) {
            viewModel.fetchMissingQuotedNotes(quotedIds)
        }
    }

    // Once quoted notes resolve, fetch their authors' profiles if not already cached.
    LaunchedEffect(notes, parentNotes) {
        val quotedIds = notes.flatMap { it.quotedEventIds }.distinct()
        if (quotedIds.isNotEmpty()) {
            viewModel.fetchMissingQuotedProfiles(quotedIds)
        }
    }

    // Zap sheet state
    var zapNoteId by remember { mutableStateOf<String?>(null) }
    val zapSheetState = rememberModalBottomSheetState(skipPartiallyExpanded = true)

    // Zap result feedback
    LaunchedEffect(Unit) {
        viewModel.zapMessage.collect { msg ->
            Toast.makeText(context, msg, Toast.LENGTH_SHORT).show()
        }
    }

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

    // Scroll-direction detection → drives the bottom-bar + FAB condense animation.
    ScrollCondenseEffect(
        scrollKey = listState,
        firstVisibleItemIndex = { listState.firstVisibleItemIndex },
        firstVisibleItemScrollOffset = { listState.firstVisibleItemScrollOffset },
        setScrollingDown = viewModel::setFeedScrollingDown,
    )

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
                        // The reveal effect below performs the scroll once the
                        // prepend has actually landed in the list — scrolling
                        // here (even after a fixed delay) races composition and
                        // strands the new post above the viewport.
                        viewModel.applyPendingNotes()
                    }
                }
            }
    }

    // iOS-parity reveal. The keyed LazyColumn anchors the previous top item
    // whenever notes are prepended, which strands the new notes above the
    // viewport (only their bottom edge peeks out behind the translucent
    // toolbar) — SwiftUI's ScrollView doesn't anchor, so iOS reveals new
    // posts naturally. Watching the first note id is the only reliable
    // signal that a prepend has actually composed; fixed delays race the
    // filter-recompute debounce and the frame clock. When the first id
    // changes while the user is (or just was) at the top, scroll to the
    // absolute top so the new post lands fully in view below the toolbar.
    // Also covers replies, which insert directly and bypass pendingNotes.
    LaunchedEffect(Unit) {
        var prevFirstId: String? = null
        var wasAtTop = true
        snapshotFlow { notes.firstOrNull()?.id to isAtTop }
            .collect { (firstId, atTop) ->
                // Prepend = first id changed but the old first note is still
                // in the list (a refresh/reload replaces it entirely).
                val prepended = firstId != null && prevFirstId != null &&
                    firstId != prevFirstId && notes.any { it.id == prevFirstId }
                if (prepended && (wasAtTop || atTop)) {
                    listState.animateScrollToItem(0)
                }
                prevFirstId = firstId
                wasAtTop = atTop
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
            // Reading the flag inside this slot keeps recomposition scoped to the
            // FAB — the feed list never re-renders when it shows/hides.
            val scrollingDown by viewModel.feedScrollingDown.collectAsState()
            // The FAB hides and shows with the scroll, so it is chrome.
            val fabSpring = Motion.chrome<Float>()
            AnimatedVisibility(
                visible = !scrollingDown,
                enter = scaleIn(animationSpec = fabSpring, initialScale = 0.5f) + fadeIn(fabSpring),
                exit = scaleOut(animationSpec = fabSpring, targetScale = 0.5f) + fadeOut(fabSpring),
            ) {
                // iOS-style gradient "Post" capsule (FeedView compose FAB)
                val colors = LocalNostrVaultColors.current
                Surface(
                    onClick = onCompose,
                    shape = RoundedCornerShape(50),
                    color = Color.Transparent,
                    modifier = Modifier
                        .padding(bottom = 88.dp)
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
                            .background(
                                Brush.linearGradient(
                                    listOf(colors.primary, colors.primaryLight),
                                ),
                                RoundedCornerShape(50),
                            )
                            .height(48.dp)
                            .padding(horizontal = 18.dp),
                    ) {
                        Icon(
                            NostrVaultIcons.Create,
                            contentDescription = "Compose",
                            tint = Color.White,
                            modifier = Modifier.size(18.dp),
                        )
                        Text(
                            text = "Post",
                            color = Color.White,
                            fontSize = 14.sp,
                            fontWeight = FontWeight.Bold,
                        )
                    }
                }
            }
        },
    ) { padding ->
        Box(modifier = Modifier.fillMaxSize()) {
        PullToRefreshBox(
            isRefreshing = isRefreshing,
            onRefresh = viewModel::refresh,
            modifier = Modifier.fillMaxSize(),
        ) {
            if (feedMode == FeedMode.LIVE) {
                LiveGrid(
                    streams = liveStreams,
                    profiles = allProfiles,
                    isLoading = liveLoading,
                    contentPadding = padding,
                    onStreamClick = { playingStream = it },
                    onRefresh = viewModel::refreshLive,
                )
            } else if (feedMode == FeedMode.ARTICLES || feedMode == FeedMode.RECIPES) {
                ArticleList(
                    mode = feedMode,
                    notes = notes,
                    profiles = allProfiles,
                    isRefreshing = isRefreshing,
                    contentPadding = padding,
                    onArticleClick = onArticleClick,
                    onRefresh = viewModel::refresh,
                )
            } else if (feedMode == FeedMode.MEDIA) {
                MediaFeedGrid(
                    notes = mediaNotes,
                    isRefreshing = isRefreshing,
                    isLoadingMore = isLoadingMore,
                    contentPadding = padding,
                    onNoteClick = onNoteClick,
                    onLoadMore = viewModel::loadMore,
                )
            } else if (notes.isEmpty() && isRefreshing) {
                // Shimmer skeleton loading
                SkeletonFeed(count = 5)
            } else if (notes.isEmpty()) {
                EmptyFeedPlaceholder(feedMode, onRefresh = viewModel::refresh)
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

                        // Exactly the pubkeys this card can render: its author, the
                        // reposter, the reply target, and anyone the text mentions.
                        // Quoted notes and the parent are added below where they resolve.
                        val headPubkeys = remember(note.id) {
                            buildList {
                                add(note.pubkey)
                                note.repostedBy?.let(::add)
                                note.replyToPubkey?.let(::add)
                                addAll(NostrMentions.mentionedPubkeys(note.content))
                            }.distinct()
                        }

                        // Remove expensive Crossfade animation for better scroll performance
                        if (showCompact) {
                            // derivedStateOf, not a plain read: the computation re-runs on
                            // every metadata batch, but this row only recomposes when one of
                            // *its* profiles actually changed. Reading allProfiles directly
                            // here would rebuild every visible card per batch instead.
                            val cardProfiles by remember(headPubkeys) {
                                derivedStateOf { headPubkeys.resolveAgainst(allProfiles) }
                            }
                            CompactNoteCard(
                                note = note,
                                profile = cardProfiles[note.pubkey],
                                profiles = cardProfiles,
                                repostedByProfile = note.repostedBy?.let { cardProfiles[it] },
                                onNoteClick = { id ->
                                    // Expand inline first instead of navigating
                                    expandedNoteId = id
                                },
                                onProfileClick = onProfileClick,
                                modifier = Modifier.padding(horizontal = 10.dp, vertical = 2.dp),
                            )
                        } else {
                            val parentEventId = note.parentEventId
                            val parentNote = parentEventId?.let { viewModel.parentNoteFor(it) }
                            val isParentNext = parentEventId?.let { viewModel.isParentNext(note.id) } ?: false

                            // Resolve embedded quoted events, keyed by the same
                            // lookup key NoteCard reads. Keyed on quotedNotes so
                            // the map rebuilds when one arrives — including an
                            // article, which lands in the by-coordinate cache.
                            val quotedNotesMap = remember(note.id, note.quotedEventIds, quotedNotes) {
                                if (note.quotedEventIds.isEmpty()) {
                                    emptyMap()
                                } else {
                                    note.quotedEventIds.mapNotNull { qid ->
                                        viewModel.quotedNoteFor(qid)?.let { qid to it }
                                    }.toMap()
                                }
                            }

                            // See the compact branch: derivedStateOf keeps a metadata
                            // batch from recomposing cards it did not touch. The parent and
                            // quoted authors join the set once those notes resolve.
                            val cardPubkeys = remember(headPubkeys, parentNote?.pubkey, quotedNotesMap) {
                                (headPubkeys +
                                    listOfNotNull(parentNote?.pubkey) +
                                    quotedNotesMap.values.map { it.pubkey }).distinct()
                            }
                            val cardProfiles by remember(cardPubkeys) {
                                derivedStateOf { cardPubkeys.resolveAgainst(allProfiles) }
                            }

                            NoteCard(
                                note = note,
                                profile = cardProfiles[note.pubkey],
                                stats = viewModel.statsFor(note.id),
                                profiles = cardProfiles,
                                quotedNotes = quotedNotesMap,
                                isLiked = viewModel.isLiked(note.id),
                                isZapped = viewModel.isZapped(note.id),
                                isReposted = note.effectiveEventId in repostedIds,
                                repostedByProfile = note.repostedBy?.let { cardProfiles[it] },
                                replyToProfile = note.replyToPubkey?.let { cardProfiles[it] },
                                parentNote = parentNote,
                                parentIsNext = isParentNext,
                                showReplyContext = true,
                                onNoteClick = onNoteClick,
                                onArticleClick = onArticleClick,
                                onProfileClick = onProfileClick,
                                onLike = viewModel::likeNote,
                                onRepost = viewModel::repostNote,
                                onZap = { id -> zapNoteId = id },
                                onReply = onReply ?: { _ -> onCompose() },
                                onQuote = onQuote,
                                onShare = { id ->
                                    val shareNote = notes.find { it.id == id || it.effectiveEventId == id }
                                    val shareText = shareNote?.content ?: "nostr:${id}"
                                    val intent = Intent(Intent.ACTION_SEND).apply {
                                        type = "text/plain"
                                        putExtra(Intent.EXTRA_TEXT, shareText)
                                    }
                                    context.startActivity(Intent.createChooser(intent, "Share Note"))
                                },
                                onBroadcast = { id -> broadcastNoteId = id },
                                onMore = if (viewModel.isOwnNote(note.pubkey)) {
                                    { id -> moreMenuNoteId = id }
                                } else null,
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
                        // Scroll toward the top right away; if the animation
                        // outruns the prepend, the reveal effect snaps the
                        // last bit once the new first note composes.
                        scope.launch { listState.animateScrollToItem(0) }
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
        val targetNote = notes.find { it.id == moreMenuNoteId || it.effectiveEventId == moreMenuNoteId }
        val isOwn = targetNote != null && viewModel.isOwnNote(targetNote.pubkey)

        AlertDialog(
            onDismissRequest = { moreMenuNoteId = null },
            title = { Text("Actions") },
            text = {
                Column {
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

    // The live player takes over the screen rather than living on a nav route:
    // it needs the LiveStream object it was opened with, and a route argument
    // would mean re-resolving a replaceable event that may already be gone.
    playingStream?.let { stream ->
        LiveStreamScreen(
            stream = stream,
            hostName = allProfiles[stream.hostPubkey]?.bestName,
            onBack = { playingStream = null },
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
    val broadcastNote = broadcastNoteId?.let { id -> notes.find { it.id == id || it.effectiveEventId == id } }
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
        val feedConfig by viewModel.configStoreRef.config.collectAsState()
        com.nostrvault.ui.screens.dashboard.FeedConfigSheet(
            showReposts = showReposts,
            showReplies = showReplies,
            autoLoadNewNotes = autoLoad,
            feedRelays = feedConfig.activeFeedRelays,
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

// ── Media grid ───────────────────────────────────────────────────

/**
 * Instagram-style 3-column media grid for FeedMode.MEDIA (iOS parity with
 * FeedView.mediaGridView). Each cell shows a note's first media URL as a square
 * thumbnail; tapping opens a full-screen swipeable pager across every cell's
 * media, and long-pressing opens the note's detail view.
 */
@OptIn(ExperimentalFoundationApi::class)
/**
 * The Articles mode list: one card per long-form post, drawn from tags only so
 * a 20,000-word body never gets laid out to render a row. Tapping opens the
 * reader rather than the note screen — the note screen renders kind-1 threads,
 * and would show the Markdown source.
 */
@Composable
private fun ArticleList(
    mode: FeedMode,
    notes: List<FeedNote>,
    profiles: Map<String, FeedProfile>,
    isRefreshing: Boolean,
    contentPadding: PaddingValues,
    onArticleClick: (String) -> Unit,
    onRefresh: () -> Unit,
) {
    if (notes.isEmpty()) {
        if (!isRefreshing) EmptyFeedPlaceholder(mode, onRefresh = onRefresh)
        return
    }

    val colors = LocalNostrVaultColors.current
    LazyColumn(
        contentPadding = contentPadding,
        modifier = Modifier.fillMaxSize(),
    ) {
        items(notes, key = { it.id }) { note ->
            val meta = remember(note.id, note.tags) { ArticleMeta.from(note) }
            Column(
                modifier = Modifier
                    .fillMaxWidth()
                    .clickable { onArticleClick(note.id) }
                    .padding(horizontal = 16.dp, vertical = 14.dp),
            ) {
                meta.imageUrl?.let { url ->
                    AsyncImage(
                        model = url,
                        contentDescription = null,
                        contentScale = ContentScale.Crop,
                        modifier = Modifier
                            .fillMaxWidth()
                            .height(140.dp)
                            .clip(RoundedCornerShape(10.dp)),
                    )
                    Spacer(Modifier.height(10.dp))
                }
                Text(
                    text = meta.title,
                    color = PrimaryText,
                    fontSize = 17.sp,
                    fontWeight = FontWeight.SemiBold,
                    lineHeight = 22.sp,
                    maxLines = 2,
                    overflow = TextOverflow.Ellipsis,
                )
                meta.summary?.let {
                    Spacer(Modifier.height(6.dp))
                    Text(
                        text = it,
                        color = SecondaryText,
                        fontSize = 14.sp,
                        lineHeight = 19.sp,
                        maxLines = 3,
                        overflow = TextOverflow.Ellipsis,
                    )
                }
                Spacer(Modifier.height(8.dp))
                Text(
                    text = buildString {
                        append(profiles[note.pubkey]?.bestName ?: note.pubkey.take(8))
                        append(" · ")
                        append(DateFormat.getDateInstance(DateFormat.MEDIUM).format(meta.publishedAt))
                    },
                    color = TertiaryText,
                    fontSize = 12.sp,
                )
            }
            HorizontalDivider(color = colors.primary.copy(alpha = 0.10f))
        }
    }
}

/**
 * Live streams (NIP-53). Only playable ones reach here — LiveFeedService drops
 * anything that has ended or whose URL the player cannot open, because a tile
 * for one of those can only disappoint.
 */
@Composable
private fun LiveGrid(
    streams: List<LiveStream>,
    profiles: Map<String, FeedProfile>,
    isLoading: Boolean,
    contentPadding: PaddingValues,
    onStreamClick: (LiveStream) -> Unit,
    onRefresh: () -> Unit,
) {
    val colors = LocalNostrVaultColors.current
    if (streams.isEmpty()) {
        Box(contentAlignment = Alignment.Center, modifier = Modifier.fillMaxSize()) {
            if (isLoading) {
                CircularProgressIndicator(color = colors.primary)
            } else {
                EmptyFeedPlaceholder(FeedMode.LIVE, onRefresh = onRefresh)
            }
        }
        return
    }

    LazyColumn(contentPadding = contentPadding, modifier = Modifier.fillMaxSize()) {
        items(streams, key = { it.address }) { stream ->
            Column(
                modifier = Modifier
                    .fillMaxWidth()
                    .clickable { onStreamClick(stream) }
                    .padding(horizontal = 16.dp, vertical = 12.dp),
            ) {
                stream.imageUrl?.let { url ->
                    AsyncImage(
                        model = url,
                        contentDescription = null,
                        contentScale = ContentScale.Crop,
                        modifier = Modifier
                            .fillMaxWidth()
                            .aspectRatio(16f / 9f)
                            .clip(RoundedCornerShape(10.dp)),
                    )
                    Spacer(Modifier.height(8.dp))
                }
                Text(
                    text = stream.title ?: "Untitled stream",
                    color = PrimaryText,
                    fontSize = 16.sp,
                    fontWeight = FontWeight.SemiBold,
                    maxLines = 2,
                    overflow = TextOverflow.Ellipsis,
                )
                Spacer(Modifier.height(4.dp))
                Text(
                    text = buildString {
                        append(profiles[stream.hostPubkey]?.bestName ?: stream.hostPubkey.take(8))
                        stream.participants?.let { append(" · $it watching") }
                    },
                    color = TertiaryText,
                    fontSize = 12.sp,
                )
            }
        }
    }
}

@Composable
private fun MediaFeedGrid(
    notes: List<FeedNote>,
    isRefreshing: Boolean,
    isLoadingMore: Boolean,
    contentPadding: PaddingValues,
    onNoteClick: (String) -> Unit,
    onLoadMore: () -> Unit,
) {
    if (notes.isEmpty()) {
        if (!isRefreshing) EmptyFeedPlaceholder(FeedMode.MEDIA)
        return
    }

    val gridState = rememberLazyGridState()

    // The pager opens across the first media of every cell, so its indices line up
    // 1:1 with the grid. filterMediaNotes guarantees a non-empty mediaURLs per note.
    val gridUrls = remember(notes) { notes.map { it.mediaURLs.first() } }

    // Infinite scroll: load older media as the user nears the end of the grid.
    val shouldLoadMore by remember {
        derivedStateOf {
            val last = gridState.layoutInfo.visibleItemsInfo.lastOrNull()?.index ?: 0
            last >= gridState.layoutInfo.totalItemsCount - 6
        }
    }
    LaunchedEffect(shouldLoadMore) {
        if (shouldLoadMore && notes.isNotEmpty()) onLoadMore()
    }

    LazyVerticalGrid(
        columns = GridCells.Fixed(3),
        state = gridState,
        horizontalArrangement = Arrangement.spacedBy(2.dp),
        verticalArrangement = Arrangement.spacedBy(2.dp),
        contentPadding = PaddingValues(
            top = contentPadding.calculateTopPadding(),
            bottom = contentPadding.calculateBottomPadding() + 88.dp,
        ),
        modifier = Modifier.fillMaxSize(),
    ) {
        items(
            count = notes.size,
            key = { notes[it].id },
        ) { index ->
            val note = notes[index]
            MediaGridCell(
                url = note.mediaURLs.first(),
                mediaCount = note.mediaURLs.size,
                onTap = { FullScreenMediaRouter.open(gridUrls, index) },
                onLongPress = { onNoteClick(note.id) },
            )
        }

        if (isLoadingMore) {
            item(span = { GridItemSpan(maxLineSpan) }) {
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

@OptIn(ExperimentalFoundationApi::class)
@Composable
private fun MediaGridCell(
    url: String,
    mediaCount: Int,
    onTap: () -> Unit,
    onLongPress: () -> Unit,
) {
    Box(
        modifier = Modifier
            .aspectRatio(1f)
            .combinedClickable(
                onClick = onTap,
                onLongClick = onLongPress,
            ),
    ) {
        RetryableAsyncImage(
            model = url,
            contentDescription = null,
            contentScale = ContentScale.Crop,
            modifier = Modifier.fillMaxSize(),
        )

        // Top-right indicator: stacked-squares for multi-media, play for a lone video.
        val indicator = when {
            mediaCount > 1 -> NostrVaultIcons.Layers
            isVideoUrl(url) -> NostrVaultIcons.PlayCircle
            else -> null
        }
        if (indicator != null) {
            Box(
                modifier = Modifier
                    .align(Alignment.TopEnd)
                    .padding(6.dp)
                    .clip(RoundedCornerShape(4.dp))
                    .background(Color.Black.copy(alpha = 0.6f))
                    .padding(4.dp),
            ) {
                Icon(
                    imageVector = indicator,
                    contentDescription = null,
                    tint = Color.White,
                    modifier = Modifier.size(12.dp),
                )
            }
        }
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

            // Mode-dependent filter buttons. Articles has none: reposts,
            // replies and auto-load are all about kind-1 traffic, and a
            // long-form list is short enough not to need them.
            when (feedMode) {
                FeedMode.ARTICLES, FeedMode.RECIPES, FeedMode.LIVE -> Unit
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

// iOS FeedView empty state: thin gradient icon, bold title, monospaced
// subtitle, and a full-width gradient "Refresh Feed" button.
@Composable
private fun EmptyFeedPlaceholder(mode: FeedMode, onRefresh: (() -> Unit)? = null) {
    val colors = LocalNostrVaultColors.current
    val gradient = Brush.linearGradient(listOf(colors.primary, colors.primaryLight))
    Box(
        contentAlignment = Alignment.Center,
        modifier = Modifier
            .fillMaxSize()
            .padding(horizontal = 24.dp),
    ) {
        Column(horizontalAlignment = Alignment.CenterHorizontally) {
            Icon(
                imageVector = when (mode) {
                    FeedMode.FOLLOWING -> NostrVaultIcons.PersonAdd
                    FeedMode.DISCOVERY -> NostrVaultIcons.GlobeOutline
                    FeedMode.GLOBAL -> NostrVaultIcons.Globe
                    FeedMode.POPULAR -> NostrVaultIcons.BarChart
                    FeedMode.MEDIA -> NostrVaultIcons.Media
                    FeedMode.ARTICLES -> NostrVaultIcons.Articles
                    FeedMode.RECIPES -> NostrVaultIcons.Recipes
                    FeedMode.LIVE -> NostrVaultIcons.Live
                },
                contentDescription = null,
                tint = colors.primaryLight,
                modifier = Modifier.size(56.dp),
            )
            Spacer(Modifier.height(16.dp))
            Text(
                text = when (mode) {
                    FeedMode.FOLLOWING -> "No Following Feed"
                    FeedMode.DISCOVERY -> "Discovering Notes"
                    FeedMode.GLOBAL -> "No Global Notes Yet"
                    FeedMode.POPULAR -> "No Popular Notes Yet"
                    FeedMode.MEDIA -> "No Media Found"
                    FeedMode.ARTICLES -> "No Articles Yet"
                    FeedMode.RECIPES -> "No Recipes Yet"
                    FeedMode.LIVE -> "Nothing Live"
                },
                color = PrimaryText,
                fontSize = 22.sp,
                fontWeight = FontWeight.Bold,
                letterSpacing = 0.2.sp,
            )
            Spacer(Modifier.height(12.dp))
            Text(
                text = when (mode) {
                    FeedMode.FOLLOWING -> "Follow npubs on Nostr to see their posts here"
                    FeedMode.DISCOVERY -> "Analyzing your extended network..."
                    FeedMode.GLOBAL -> "Waiting for notes from your feed relays"
                    FeedMode.POPULAR -> "Waiting for engagement data to arrive"
                    FeedMode.MEDIA -> "Photos and videos from your feed show up here"
                    FeedMode.ARTICLES -> "Long-form posts in your vault show up here"
                    FeedMode.RECIPES -> "Recipes from zap.cooking show up here"
                    FeedMode.LIVE -> "Streams that are running right now show up here"
                },
                color = SecondaryText,
                fontSize = 13.sp,
                fontFamily = FontFamily.Monospace,
                letterSpacing = 0.3.sp,
                textAlign = TextAlign.Center,
            )
            if (onRefresh != null) {
                Spacer(Modifier.height(40.dp))
                Row(
                    verticalAlignment = Alignment.CenterVertically,
                    horizontalArrangement = Arrangement.spacedBy(10.dp),
                    modifier = Modifier
                        .fillMaxWidth()
                        .background(gradient, RoundedCornerShape(10.dp))
                        .clickable(onClick = onRefresh)
                        .padding(vertical = 14.dp),
                ) {
                    Spacer(Modifier.weight(1f))
                    Icon(
                        imageVector = NostrVaultIcons.Refresh,
                        contentDescription = null,
                        tint = Color.Black,
                        modifier = Modifier.size(16.dp),
                    )
                    Text(
                        text = "Refresh Feed",
                        color = Color.Black,
                        fontSize = 14.sp,
                        fontWeight = FontWeight.SemiBold,
                    )
                    Spacer(Modifier.weight(1f))
                }
            }
        }
    }
}

// ── New posts pill ──────────────────────────────────────────────

@Composable
private fun NewPostsPill(count: Int, onClick: () -> Unit, modifier: Modifier = Modifier) {
    val colors = LocalNostrVaultColors.current
    // Mirrors iOS: Capsule fill(havenPurple/theme primary), white content,
    // soft offset drop shadow (black 40%, radius 8, y+4), 10/20 padding,
    // arrow.up size 12 bold + "N New Posts" size 13 bold.
    val shape = RoundedCornerShape(50)
    Row(
        verticalAlignment = Alignment.CenterVertically,
        modifier = modifier
            .shadow(
                elevation = 8.dp,
                shape = shape,
                ambientColor = Color.Black.copy(alpha = 0.4f),
                spotColor = Color.Black.copy(alpha = 0.4f),
            )
            .clip(shape)
            .background(colors.primary)
            .clickable(onClick = onClick)
            .padding(vertical = 10.dp, horizontal = 20.dp),
    ) {
        Icon(
            imageVector = NostrVaultIcons.ArrowUp,
            contentDescription = null,
            tint = PrimaryText,
            modifier = Modifier.size(12.dp),
        )
        Spacer(Modifier.width(8.dp))
        Text(
            text = "$count New Posts",
            fontWeight = FontWeight.Bold,
            fontSize = 13.sp,
            color = PrimaryText,
        )
    }
}

/**
 * The subset of [profiles] this list of pubkeys names, dropping the ones the
 * relay has not answered yet. Small by construction — a handful of entries per
 * feed row — so a card is handed only what it can draw rather than the whole
 * profile cache.
 */
private fun List<String>.resolveAgainst(
    profiles: Map<String, FeedProfile>,
): Map<String, FeedProfile> {
    if (isEmpty()) return emptyMap()
    val resolved = HashMap<String, FeedProfile>(size)
    for (pubkey in this) profiles[pubkey]?.let { resolved[pubkey] = it }
    return resolved
}
