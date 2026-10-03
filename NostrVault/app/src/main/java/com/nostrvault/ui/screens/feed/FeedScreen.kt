package com.nostrvault.ui.screens.feed

import android.widget.Toast
import androidx.compose.animation.AnimatedVisibility
import androidx.compose.animation.fadeIn
import androidx.compose.animation.expandHorizontally
import androidx.compose.animation.fadeOut
import androidx.compose.animation.shrinkHorizontally
import androidx.compose.animation.scaleIn
import androidx.compose.animation.scaleOut
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.LocalIndication
import androidx.compose.foundation.indication
import androidx.compose.foundation.interaction.MutableInteractionSource
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
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.semantics.stateDescription
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.shadow
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.platform.LocalClipboardManager
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.AnnotatedString
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.compose.ui.zIndex
import androidx.hilt.navigation.compose.hiltViewModel
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.filterNotNull
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.withTimeoutOrNull
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import androidx.compose.ui.text.style.TextOverflow
import coil.compose.AsyncImage
import com.nostrvault.relay.HavenBridge
import com.nostrvault.data.model.ArticleMeta
import com.nostrvault.data.model.FeedLayoutMode
import com.nostrvault.data.model.FeedMode
import com.nostrvault.data.model.FeedProfile
import com.nostrvault.data.model.LiveStream
import com.nostrvault.data.model.FeedNote
import com.nostrvault.data.model.PopularFilter
import com.nostrvault.data.model.ReelsScope
import com.nostrvault.ui.screens.LiveStreamScreen
import com.nostrvault.ui.components.CustomZapSheet
import com.nostrvault.ui.components.FullScreenMediaRouter
import com.nostrvault.ui.components.MediaSourceKey
import com.nostrvault.ui.components.MediaZoomSources
import com.nostrvault.ui.components.mediaZoomSource
import com.nostrvault.ui.components.RetryableAsyncImage
import com.nostrvault.ui.components.isVideoUrl
import com.nostrvault.ui.components.BroadcastSheet
import com.nostrvault.ui.components.EmojiPickerSheet
import com.nostrvault.ui.components.CompactNoteCard
import com.nostrvault.ui.components.FeedThreadCard
import com.nostrvault.ui.components.GlassPill
import com.nostrvault.ui.components.GlassScaffold
import com.nostrvault.ui.components.NoteCard
import com.nostrvault.ui.components.UGCReportDialog
import com.nostrvault.ui.components.threadLink
import com.nostrvault.ui.components.NostrMentions
import com.nostrvault.ui.components.ScrollCondenseEffect
import com.nostrvault.ui.components.blockedWhen
import com.nostrvault.ui.components.chromeFab
import com.nostrvault.ui.components.chromeFold
import com.nostrvault.ui.components.chromeReveal
import com.nostrvault.ui.components.newPostsFold
import com.nostrvault.ui.components.rememberChromeFolded
import com.nostrvault.ui.components.SkeletonFeed
import com.nostrvault.service.ScrollPosition
import com.nostrvault.ui.theme.*
import com.nostrvault.service.FeedLanguage
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
    /** Opens the diVine, article or recipe composer. */
    onComposeMode: (com.nostrvault.ui.screens.ModeComposerKind) -> Unit = {},
    onReply: ((String) -> Unit)? = null,
    onQuote: ((String) -> Unit)? = null,
    onNavigateToSettings: () -> Unit,
    viewModel: FeedViewModel = hiltViewModel(),
) {
    val feedMode by viewModel.feedMode.collectAsState()
    // The post button writes what the feed shows: a diVine in diVines, an
    // article in Articles, a recipe in Recipes, a note everywhere else.
    val modeComposer = when (feedMode) {
        FeedMode.REELS -> com.nostrvault.ui.screens.ModeComposerKind.DIVINE
        FeedMode.ARTICLES -> com.nostrvault.ui.screens.ModeComposerKind.ARTICLE
        FeedMode.RECIPES -> com.nostrvault.ui.screens.ModeComposerKind.RECIPE
        else -> null
    }
    val postAction: () -> Unit = { modeComposer?.let(onComposeMode) ?: onCompose() }
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
    val isLoadingExtendedNetwork by viewModel.isLoadingExtendedNetwork.collectAsState()
    val followedPubkeys by viewModel.followedPubkeys.collectAsState()
    val unavailableNoteIds by viewModel.unavailableNoteIds.collectAsState()
    val connectionColor by viewModel.connectionColor.collectAsState()
    // Read straight off the ViewModel's snapshot map. Collecting it here would
    // subscribe the whole screen to every metadata batch; each feed row narrows
    // its own read below instead.
    val allProfiles = viewModel.profileState
    val isCompact by viewModel.compactModeEnabled.collectAsState()
    val layoutMode by viewModel.layoutMode.collectAsState()
    val isThreaded by viewModel.threadedModeEnabled.collectAsState()
    val feedThreads by viewModel.feedThreads.collectAsState()
    val autoLoad by viewModel.autoLoadEnabled.collectAsState()
    val showReposts by viewModel.showReposts.collectAsState()
    val showReplies by viewModel.showReplies.collectAsState()
    val mediaFollowingOnly by viewModel.mediaFollowingOnly.collectAsState()
    val popularFilter by viewModel.popularFilter.collectAsState()
    val globalShowsEveryone by viewModel.globalShowsEveryone.collectAsState()
    val globalFeedLanguages by viewModel.globalFeedLanguages.collectAsState()
    val trustGraphReady by viewModel.trustGraphReady.collectAsState()
    val showEngagementStats by viewModel.showEngagementStats.collectAsState()
    val pendingCount by viewModel.pendingNoteCount.collectAsState()
    // The parent, quote and repost caches are not collected here. Every parent
    // or quote that resolves replaces those maps, and a read at this level
    // re-ran this whole screen and handed every visible row a new map to
    // compare — dozens of times while a page of replies streams in. Each row
    // subscribes to just its own entries in FeedFullNoteRow instead.
    val listState = rememberLazyListState()
    val context = LocalContext.current
    val clipboard = LocalClipboardManager.current
    val scope = rememberCoroutineScope()

    // Inline expansion state for compact mode (iOS parity: tap expands inline first).
    // Threaded mode's cards share this same field rather than keeping their own —
    // one selection across both condensed layouts, and it survives a card being
    // recycled off-screen and back by a LazyColumn (per-card `remember` would not).
    var expandedNoteId by remember { mutableStateOf<String?>(null) }

    // Per-thread "show more replies" fold, hoisted for the same reason: a
    // LazyColumn item's own `remember` is dropped when it scrolls out of view.
    val threadFolds = remember { mutableStateMapOf<String, Boolean>() }

    // Reset expanded note when feed mode or layout mode changes
    LaunchedEffect(feedMode, isCompact, isThreaded) {
        expandedNoteId = null
    }

    // Batch-fetch all missing parent notes whenever the visible notes list changes.
    // One REQ with all IDs instead of one REQ per item. The scan walks the
    // whole feed (up to MAX_FEED_NOTES), so it runs off the main thread;
    // only the fetch call comes back to it.
    LaunchedEffect(notes) {
        val missingIds = withContext(Dispatchers.Default) {
            notes.mapNotNull { note ->
                note.parentEventId?.takeIf { viewModel.parentNoteFor(it) == null }
            }.distinct()
        }
        if (missingIds.isNotEmpty()) {
            viewModel.fetchMissingParentNotes(missingIds)
        }
    }

    // Batch-fetch any embedded quoted notes (nostr:note1.../nevent1...) referenced
    // by the visible notes. Decoded to hex and fetched via the same path as parents.
    // Once they resolve, fetch their authors' profiles if not already cached —
    // collected here rather than keyed on the cache, so a resolving quote does
    // not recompose the screen.
    LaunchedEffect(notes) {
        val quotedIds = withContext(Dispatchers.Default) {
            notes.flatMap { it.quotedEventIds }.distinct()
        }
        if (quotedIds.isEmpty()) return@LaunchedEffect
        viewModel.fetchMissingQuotedNotes(quotedIds)
        viewModel.parentNotesCache.collect {
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
    var reportNoteId by remember { mutableStateOf<String?>(null) }
    var blockNoteId by remember { mutableStateOf<String?>(null) }

    // Emoji picker state
    var emojiPickerNoteId by remember { mutableStateOf<String?>(null) }
    val emojiSheetState = rememberModalBottomSheetState(skipPartiallyExpanded = true)

    // Broadcast sheet state
    var broadcastNoteId by remember { mutableStateOf<String?>(null) }
    val broadcastSheetState = rememberModalBottomSheetState(skipPartiallyExpanded = true)

    // Feed config sheet state
    var showFeedConfig by remember { mutableStateOf(false) }

    // Reels' Global scope is unmoderated video from the whole network; it sits
    // behind a warning (iOS parity: the same one Media's Global uses there).
    var showGlobalReelsWarning by remember { mutableStateOf(false) }
    // Global's Everyone scope sits behind the same warning (iOS parity).
    var showGlobalEveryoneWarning by remember { mutableStateOf(false) }
    val reelsScope by viewModel.reelsScope.collectAsState()

    // Trigger load-more when near bottom
    val shouldLoadMore by remember {
        derivedStateOf {
            val lastVisible = listState.layoutInfo.visibleItemsInfo.lastOrNull()?.index ?: 0
            lastVisible >= listState.layoutInfo.totalItemsCount - 5
        }
    }
    LoadMoreEffect(shouldLoadMore, isLoadingMore, notes.size, viewModel::loadMore)

    // Load the next rows' photos and avatars while these are on screen.
    // Reads the lists through rememberUpdatedState inside the effect, so a
    // new page or a metadata batch does not restart it.
    FeedPrefetchEffect(listState) { row ->
        if (isThreaded) {
            val thread = feedThreads.getOrNull(row) ?: return@FeedPrefetchEffect emptyList()
            prefetchItemsForThread(thread.entries.map { it.note to (it.depth == 0) }, allProfiles)
        } else {
            val note = notes.getOrNull(row) ?: return@FeedPrefetchEffect emptyList()
            prefetchItemsFor(note, allProfiles, compact = isCompact && expandedNoteId != note.id)
        }
    }

    // Track whether the user is at the top of the feed
    val isAtTop by remember {
        derivedStateOf {
            listState.firstVisibleItemIndex == 0 && listState.firstVisibleItemScrollOffset < 50
        }
    }

    // Where the list is relative to its top: the chrome always shows near it.
    ScrollCondenseEffect(
        scrollKey = listState,
        firstVisibleItemIndex = { listState.firstVisibleItemIndex },
        firstVisibleItemScrollOffset = { listState.firstVisibleItemScrollOffset },
    )

    // Tell the feed when a drag or fling is moving the list, so incoming
    // relay batches wait for it to settle instead of reshaping the list under
    // the finger; and save the scroll position for snapshot persistence when
    // it stops. Read through snapshotFlow, not as an effect key: a key read
    // here recomposed the whole screen at the start and end of every fling.
    LaunchedEffect(listState) {
        snapshotFlow { listState.isScrollInProgress }.collect { scrolling ->
            viewModel.setFeedScrolling(scrolling)
            if (!scrolling) {
                viewModel.saveScrollPosition(
                    listState.firstVisibleItemIndex,
                    listState.firstVisibleItemScrollOffset,
                )
            }
        }
    }
    DisposableEffect(Unit) {
        onDispose { viewModel.setFeedScrolling(false) }
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
    // Threaded mode lists thread cards, not notes: a reply moves its card to
    // the top without changing notes' first id, so watch the first key the
    // list actually renders.
    LaunchedEffect(Unit) {
        var prevFirstId: String? = null
        var wasAtTop = true
        snapshotFlow {
            val keys = if (isThreaded) feedThreads.map { it.rootId } else notes.map { it.id }
            keys to isAtTop
        }
            .collect { (keys, atTop) ->
                val firstId = keys.firstOrNull()
                // Prepend = first key changed but the old first item is still
                // in the list (a refresh/reload replaces it entirely).
                val prepended = firstId != null && prevFirstId != null &&
                    firstId != prevFirstId && prevFirstId in keys
                if (prepended && (wasAtTop || atTop)) {
                    // requestScrollToItem wins over the next layout's key
                    // anchoring. animateScrollToItem could run before that
                    // layout, see index 0, do nothing, and leave the new
                    // item above the viewport.
                    listState.requestScrollToItem(0)
                }
                prevFirstId = firstId
                wasAtTop = atTop
            }
    }

    // Keep your place when switching layouts (iOS PR #130). Expanded and
    // condensed rows are keyed by note id, threaded cards by thread root, so
    // the LazyColumn's own key anchoring loses the post on any switch to or
    // from threaded. The switch reads the topmost visible row in the layout
    // being left; once the new layout's rows exist, the row that shows the
    // same note (its thread card, or the note itself) is brought to the top.
    var layoutAnchor by remember { mutableStateOf<Pair<FeedLayoutAnchor, FeedLayoutMode>?>(null) }
    val captureLayoutAnchor: () -> FeedLayoutAnchor? = {
        val rows = listState.layoutInfo.visibleItemsInfo.map { Triple(it.index, it.offset, it.size) }
        FeedLayoutAnchor.topRowIndex(rows)?.let { row ->
            if (isThreaded) feedThreads.getOrNull(row)?.let(FeedLayoutAnchor::thread)
            else notes.getOrNull(row)?.let { FeedLayoutAnchor.note(it.id) }
        }
    }
    LaunchedEffect(layoutAnchor) {
        val (anchor, from) = layoutAnchor ?: return@LaunchedEffect
        // The new rows arrive a frame or two later (and a thread grouping
        // after that); give up quietly if the note has left the feed.
        val row = withTimeoutOrNull(2_000) {
            snapshotFlow {
                when {
                    layoutMode == from -> null
                    isThreaded != (layoutMode == FeedLayoutMode.THREADED) -> null
                    isThreaded -> anchor.indexInThreads(feedThreads)
                    else -> anchor.indexInNotes(notes.map { it.id })
                }
            }.filterNotNull().first()
        }
        if (row != null) listState.requestScrollToItem(row)
        layoutAnchor = null
    }

    // Handle tab re-selection: scroll to top or refresh if already at top
    LaunchedEffect(Unit) {
        viewModel.scrollToTopRequest.collect {
            // Reels has no list to scroll, and the untouched list below it
            // always reads as "at top" — a reselect must not wipe the viewer's
            // place by refreshing.
            if (viewModel.feedMode.value == FeedMode.REELS) return@collect
            if (isAtTop) {
                viewModel.refresh()
            } else {
                listState.scrollToItem(0) // Instant scroll for better performance
            }
        }
    }

    // Posts are waiting and either auto-load is off or the user has scrolled
    // away from the top.
    val showNewPosts = pendingCount > 0 && (!autoLoad || !isAtTop) && feedMode != FeedMode.REELS
    val loadNewPosts: () -> Unit = {
        viewModel.applyPendingNotes()
        // Scroll toward the top right away; if the animation
        // outruns the prepend, the reveal effect snaps the
        // last bit once the new first note composes.
        scope.launch { listState.animateScrollToItem(0) }
    }

    GlassScaffold(
        // Reels draw edge to edge in black; a window-coloured band fading out
        // behind the toolbar would sit over the top of every video.
        containerColor = if (feedMode == FeedMode.REELS) Color.Black else WindowBackground,
        toolbar = {
            // Read here so only the toolbar recomposes when the feed scrolls.
            val scrollingDown by viewModel.feedScrollingDown.collectAsState()
            FeedTopBar(
                feedMode = feedMode,
                collapsed = scrollingDown,
                connectionStatus = connectionStatus,
                connectionColor = connectionColor,
                layoutMode = layoutMode,
                autoLoad = autoLoad,
                showReposts = showReposts,
                showReplies = showReplies,
                mediaFollowingOnly = mediaFollowingOnly,
                popularFilter = popularFilter,
                showEngagementStats = showEngagementStats,
                globalShowsEveryone = globalShowsEveryone,
                globalFeedLanguages = globalFeedLanguages,
                // Reads the setting at tap time; leaving the Web of Trust
                // goes through the warning, coming back does not.
                onToggleTrustScope = {
                    if (viewModel.globalShowsEveryone.value) viewModel.setGlobalShowsEveryone(false)
                    else showGlobalEveryoneWarning = true
                },
                onSetGlobalLanguages = viewModel::setGlobalFeedLanguages,
                reelsGlobal = reelsScope == ReelsScope.GLOBAL,
                onReelsFollowing = { viewModel.setReelsScope(ReelsScope.FOLLOWING) },
                onReelsGlobal = { showGlobalReelsWarning = true },
                onModeChange = viewModel::setFeedMode,
                onCycleLayoutMode = {
                    layoutAnchor = captureLayoutAnchor()?.let { it to layoutMode }
                    viewModel.cycleLayoutMode()
                },
                onToggleAutoLoad = viewModel::toggleAutoLoad,
                onToggleReposts = viewModel::toggleShowReposts,
                onToggleReplies = viewModel::toggleShowReplies,
                onToggleMediaFollowing = viewModel::toggleMediaFollowing,
                onSetPopularFilter = viewModel::setPopularFilter,
                onToggleEngagementStats = viewModel::toggleShowEngagementStats,
                onOpenFeedDashboard = { showFeedConfig = true },
                newPostsCount = if (showNewPosts) pendingCount else 0,
                onLoadNewPosts = loadNewPosts,
            )
        },
        floatingActionButton = {
            // Reading the flag inside this slot keeps recomposition scoped to the
            // FAB — the feed list never re-renders when it shows/hides.
            // The FAB folds with the bars, following the finger.
            val folded by rememberChromeFolded()
            // Reels has its own reply button, and the rail sits where the FAB would.
            if (feedMode != FeedMode.REELS) Box(Modifier.chromeFab().blockedWhen(folded)) {
                // iOS-style gradient "Post" capsule (FeedView compose FAB)
                val colors = LocalNostrVaultColors.current
                Surface(
                    onClick = postAction,
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
                            when (modeComposer) {
                                com.nostrvault.ui.screens.ModeComposerKind.ARTICLE -> NostrVaultIcons.Articles
                                com.nostrvault.ui.screens.ModeComposerKind.RECIPE -> NostrVaultIcons.Recipes
                                else -> NostrVaultIcons.Create
                            },
                            contentDescription = "Compose",
                            tint = Color.White,
                            modifier = Modifier.size(18.dp),
                        )
                        Text(
                            text = modeComposer?.buttonTitle ?: "Post",
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
            if (feedMode == FeedMode.REELS) {
                ReelsFeed(
                    viewModel = viewModel,
                    profiles = allProfiles,
                    topInset = padding.calculateTopPadding(),
                    isCovered = showGlobalReelsWarning || showFeedConfig,
                    onProfile = onProfileClick,
                    // Reels are not in the feed's note list; register the note
                    // so the compose and thread screens can resolve it by id.
                    onReply = { note ->
                        viewModel.cacheNote(note)
                        onReply?.invoke(note.id) ?: onCompose()
                    },
                    onOpenNote = { note ->
                        viewModel.cacheNote(note)
                        onNoteClick(note.id)
                    },
                    onPost = { onComposeMode(com.nostrvault.ui.screens.ModeComposerKind.DIVINE) },
                    onShowGlobal = { showGlobalReelsWarning = true },
                )
            } else if (feedMode == FeedMode.LIVE) {
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
                // "Analyzing your extended network..." is only true while it is
                // actually analyzing. Once it has finished and come back with
                // nobody, say which of the two things happened: you follow
                // nobody (yours to fix), or the relays returned no follow lists
                // (not yours). Telling someone with 400 follows to follow more
                // people reads as the feature being broken by them.
                EmptyFeedPlaceholder(
                    feedMode,
                    onRefresh = viewModel::refresh,
                    subtitleOverride = if (feedMode == FeedMode.DISCOVERY && !isLoadingExtendedNetwork) {
                        if (followedPubkeys.isEmpty()) {
                            "Follow npubs on Nostr to build your extended network"
                        } else {
                            "No follow lists came back from your relays \u2014 try refreshing"
                        }
                    } else if (feedMode == FeedMode.GLOBAL && !globalShowsEveryone && !trustGraphReady) {
                        // Global fails closed without the trust graph; say so
                        // rather than "waiting for notes" over a full inbox.
                        "Building your Web of Trust\u2026 Tap the shield to see everyone"
                    } else if (feedMode == FeedMode.GLOBAL && globalFeedLanguages.isNotEmpty()) {
                        "Nothing in ${FeedLanguage.summary(globalFeedLanguages)} yet"
                    } else {
                        null
                    },
                )
            } else {
                LazyColumn(
                    state = listState,
                    contentPadding = PaddingValues(
                        top = padding.calculateTopPadding(),
                        bottom = padding.calculateBottomPadding() + 88.dp,
                    ),
                    modifier = Modifier.fillMaxSize(),
                ) {
                    if (isThreaded) {
                        items(feedThreads, key = { it.rootId }) { thread ->
                            FeedThreadCard(
                                thread = thread,
                                profileFor = { pubkey -> allProfiles[pubkey] },
                                profiles = allProfiles,
                                openNoteId = expandedNoteId,
                                onOpenNoteChange = { id -> expandedNoteId = id },
                                isExpanded = threadFolds[thread.rootId] ?: false,
                                onExpandedChange = { expanded -> threadFolds[thread.rootId] = expanded },
                                onProfileClick = onProfileClick,
                                onOpenThread = { note -> onNoteClick(note.id) },
                                onFetchMissingNote = viewModel::fetchMissingNote,
                                rootUnavailable = thread.rootId in unavailableNoteIds,
                                modifier = Modifier.padding(horizontal = 10.dp, vertical = 4.dp),
                                expandedRow = { note, _ ->
                                    FeedFullNoteRow(
                                        note = note,
                                        viewModel = viewModel,
                                        allProfiles = allProfiles,
                                        onNoteClick = onNoteClick,
                                        onArticleClick = onArticleClick,
                                        onProfileClick = onProfileClick,
                                        onReply = onReply ?: { _ -> onCompose() },
                                        onQuote = onQuote ?: {},
                                        onZap = { id -> zapNoteId = id },
                                        onBroadcast = { id -> broadcastNoteId = id },
                                        onReport = { id -> reportNoteId = id },
                                        onBlock = { id -> blockNoteId = id },
                                        onDelete = { id -> deleteNoteId = id },
                                        onLongPressLike = { id -> emojiPickerNoteId = id },
                                    )
                                },
                            )
                        }
                    } else {
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
                            FeedFullNoteRow(
                                note = note,
                                viewModel = viewModel,
                                allProfiles = allProfiles,
                                onNoteClick = onNoteClick,
                                onArticleClick = onArticleClick,
                                onProfileClick = onProfileClick,
                                onReply = onReply ?: { _ -> onCompose() },
                                onQuote = onQuote ?: {},
                                onZap = { id -> zapNoteId = id },
                                onBroadcast = { id -> broadcastNoteId = id },
                                onReport = { id -> reportNoteId = id },
                                onBlock = { id -> blockNoteId = id },
                                onDelete = { id -> deleteNoteId = id },
                                onLongPressLike = { id -> emojiPickerNoteId = id },
                                modifier = Modifier.padding(horizontal = 10.dp, vertical = 4.dp),
                            )
                        }
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

            // Floating "New Posts" pill. It folds away with the bars, rising
            // back under the top bar; folded, the small pill in the top bar's
            // row stands in for it (iOS `NewPostsFold`).
            if (showNewPosts) {
                val folded by rememberChromeFolded()
                NewPostsPill(
                    count = pendingCount,
                    onClick = loadNewPosts,
                    modifier = Modifier
                        .align(Alignment.TopCenter)
                        .padding(top = padding.calculateTopPadding() + 12.dp)
                        .zIndex(1f)
                        .newPostsFold()
                        .blockedWhen(folded)
                )
            }
        }
    }

    if (showGlobalEveryoneWarning) {
        AlertDialog(
            onDismissRequest = { showGlobalEveryoneWarning = false },
            title = { Text("Sensitive Content Warning") },
            text = {
                Text("Everyone shows posts from people outside your Web of Trust, unfiltered. Expect spam and sensitive content.")
            },
            confirmButton = {
                TextButton(
                    onClick = {
                        viewModel.setGlobalShowsEveryone(true)
                        showGlobalEveryoneWarning = false
                    },
                ) { Text("Proceed", color = ErrorRed) }
            },
            dismissButton = {
                TextButton(onClick = { showGlobalEveryoneWarning = false }) { Text("Cancel") }
            },
        )
    }

    if (showGlobalReelsWarning) {
        AlertDialog(
            onDismissRequest = { showGlobalReelsWarning = false },
            title = { Text("Sensitive Content Warning") },
            text = {
                Text(
                    "The global media feed shows unmoderated content shared across the entire " +
                        "Nostr network. This may include sensitive, explicit, or NSFW media.",
                )
            },
            confirmButton = {
                TextButton(
                    onClick = {
                        viewModel.setReelsScope(ReelsScope.GLOBAL)
                        showGlobalReelsWarning = false
                    },
                ) { Text("Proceed", color = ErrorRed) }
            },
            dismissButton = {
                TextButton(onClick = { showGlobalReelsWarning = false }) { Text("Cancel") }
            },
        )
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

    // Report dialog (NIP-56 reason picker). Reporting also blocks the author,
    // matching NoteDetailScreen and iOS.
    val reportTarget = reportNoteId?.let { id -> notes.find { it.id == id || it.effectiveEventId == id } }
    if (reportTarget != null) {
        UGCReportDialog(
            onReport = { reason, description ->
                viewModel.reportNote(
                    reportTarget.effectiveEventId,
                    reportTarget.pubkey,
                    reason,
                    description,
                )
                reportNoteId = null
            },
            onDismiss = { reportNoteId = null },
        )
    }

    // Block confirmation
    val blockTarget = blockNoteId?.let { id -> notes.find { it.id == id || it.effectiveEventId == id } }
    if (blockTarget != null) {
        AlertDialog(
            onDismissRequest = { blockNoteId = null },
            title = { Text("Block User") },
            text = { Text("Block this user? Their posts will be hidden from your feed.") },
            confirmButton = {
                TextButton(
                    onClick = {
                        viewModel.blockUser(blockTarget.pubkey)
                        blockNoteId = null
                    },
                ) { Text("Block", color = ErrorRed) }
            },
            dismissButton = {
                TextButton(onClick = { blockNoteId = null }) { Text("Cancel") }
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
    val zoomOrigin = remember { MediaZoomSources.newOrigin() }

    // Infinite scroll: load older media as the user nears the end of the grid.
    val shouldLoadMore by remember {
        derivedStateOf {
            val last = gridState.layoutInfo.visibleItemsInfo.lastOrNull()?.index ?: 0
            last >= gridState.layoutInfo.totalItemsCount - 6
        }
    }
    LoadMoreEffect(shouldLoadMore, isLoadingMore, notes.size, onLoadMore)

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
                sourceKey = MediaSourceKey(zoomOrigin, index),
                onTap = { FullScreenMediaRouter.open(gridUrls, index, zoomOrigin) },
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
    sourceKey: MediaSourceKey,
    onTap: () -> Unit,
    onLongPress: () -> Unit,
) {
    Box(
        modifier = Modifier
            .aspectRatio(1f)
            .mediaZoomSource(sourceKey, crop = true)
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

// ── Full note row ───────────────────────────────────────────────
// The expanded-mode card, factored out so the flat feed and a tapped-open
// line inside a FeedThreadCard render the exact same row (same profile
// resolution, same callbacks) instead of drifting apart.

@Composable
private fun FeedFullNoteRow(
    note: FeedNote,
    viewModel: FeedViewModel,
    allProfiles: Map<String, FeedProfile>,
    onNoteClick: (String) -> Unit,
    onArticleClick: (String) -> Unit,
    onProfileClick: (String) -> Unit,
    onReply: (String) -> Unit,
    onQuote: (String) -> Unit,
    onZap: (String) -> Unit,
    onBroadcast: (String) -> Unit,
    onReport: (String) -> Unit,
    onBlock: (String) -> Unit,
    onDelete: (String) -> Unit,
    onLongPressLike: (String) -> Unit,
    modifier: Modifier = Modifier,
) {
    val headPubkeys = remember(note.id) {
        buildList {
            add(note.pubkey)
            note.repostedBy?.let(::add)
            note.replyToPubkey?.let(::add)
            addAll(NostrMentions.mentionedPubkeys(note.content))
        }.distinct()
    }
    // Subscribed here, not read with `viewModel.isLiked(...)`: a plain
    // StateFlow `.value` read is invisible to Compose, so the row skipped
    // recomposition and a tapped heart, a zap, new counts or a late-arriving
    // parent never showed until the row scrolled off and back. derivedStateOf
    // narrows each to this note, so another note's like does not redraw it.
    val likedState = viewModel.likedEventIds.collectAsState()
    val zappedState = viewModel.zappedEventIds.collectAsState()
    val statsState = viewModel.noteStats.collectAsState()
    val parentsState = viewModel.parentNotesCache.collectAsState()
    val parentNextState = viewModel.parentIsNextNote.collectAsState()
    val quotedState = viewModel.quotedNotesCache.collectAsState()
    val repostedState = viewModel.repostedEventIds.collectAsState()
    // Likes and zaps are recorded against effectiveEventId (EngagementBar
    // sends it) and reactions are counted against the e-tag target, so a
    // repost is looked up by the note it reposts.
    val isLiked by remember(note.id) { derivedStateOf { note.effectiveEventId in likedState.value } }
    val isZapped by remember(note.id) { derivedStateOf { note.effectiveEventId in zappedState.value } }
    val stats by remember(note.id) { derivedStateOf { statsState.value[note.effectiveEventId] } }
    val parentEventId = note.parentEventId
    val parentNote by remember(note.id) { derivedStateOf { parentEventId?.let { parentsState.value[it] } } }
    val isParentNext by remember(note.id) {
        derivedStateOf { parentEventId != null && note.id in parentNextState.value }
    }

    val isReposted by remember(note.id) { derivedStateOf { note.effectiveEventId in repostedState.value } }
    // The read of quotedState is what subscribes; quotedNoteFor resolves against
    // the same caches. A parent landing for some other note recomputes this
    // but compares equal, so this row does not redraw.
    val quotedNotesMap by remember(note.id) {
        derivedStateOf {
            quotedState.value
            if (note.quotedEventIds.isEmpty()) {
                emptyMap()
            } else {
                note.quotedEventIds.mapNotNull { qid -> viewModel.quotedNoteFor(qid)?.let { qid to it } }.toMap()
            }
        }
    }

    val cardPubkeys = remember(headPubkeys, parentNote?.pubkey, quotedNotesMap) {
        (headPubkeys + listOfNotNull(parentNote?.pubkey) + quotedNotesMap.values.map { it.pubkey }).distinct()
    }
    val cardProfiles by remember(cardPubkeys) {
        derivedStateOf { cardPubkeys.resolveAgainst(allProfiles) }
    }

    NoteCard(
        note = note,
        profile = cardProfiles[note.pubkey],
        stats = stats,
        profiles = cardProfiles,
        quotedNotes = quotedNotesMap,
        isLiked = isLiked,
        isZapped = isZapped,
        isReposted = isReposted,
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
        onZap = onZap,
        onReply = onReply,
        onQuote = onQuote,
        onBroadcast = onBroadcast,
        // Every note gets an overflow menu. Gating this on your own notes
        // meant other people's notes had no menu at all, so reporting and
        // blocking were only reachable two navigations deep — from the note
        // screen, which you have to open the content to see.
        isOwnNote = viewModel.isOwnNote(note.pubkey),
        onReport = { onReport(note.id) },
        onBlock = { onBlock(note.id) },
        onDelete = { onDelete(note.id) },
        onLongPressLike = onLongPressLike,
        modifier = modifier,
    )
}

// ── Top bar ──────────────────────────────────────────────────────

@Composable
private fun FeedTopBar(
    feedMode: FeedMode,
    /// Folded past halfway with the bottom bar (the pieces fold continuously
    /// with the finger, via chromeFold): only the connection dot and the
    /// layout button stay, like the iOS top bar. Folded pieces take no taps.
    collapsed: Boolean,
    connectionStatus: String,
    connectionColor: String,
    layoutMode: FeedLayoutMode,
    autoLoad: Boolean,
    showReposts: Boolean,
    showReplies: Boolean,
    mediaFollowingOnly: Boolean,
    popularFilter: PopularFilter,
    showEngagementStats: Boolean,
    globalShowsEveryone: Boolean,
    globalFeedLanguages: List<String>,
    onToggleTrustScope: () -> Unit,
    onSetGlobalLanguages: (List<String>) -> Unit,
    reelsGlobal: Boolean,
    onReelsFollowing: () -> Unit,
    onReelsGlobal: () -> Unit,
    onModeChange: (FeedMode) -> Unit,
    onCycleLayoutMode: () -> Unit,
    onToggleAutoLoad: () -> Unit,
    onToggleReposts: () -> Unit,
    onToggleReplies: () -> Unit,
    onToggleMediaFollowing: () -> Unit,
    onSetPopularFilter: (PopularFilter) -> Unit,
    onToggleEngagementStats: () -> Unit,
    onOpenFeedDashboard: () -> Unit,
    /** Posts are waiting and the floating "New Posts" button is up. */
    newPostsCount: Int,
    onLoadNewPosts: () -> Unit,
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
            .padding(horizontal = 12.dp, vertical = 8.dp)
            // The list's top padding is this bar's height; holding it while
            // the pills fold keeps the feed from jumping under your thumb.
            .heightIn(min = 48.dp),
    ) {
        // ── Leading pill: one tap target. The icon names the current feed and
        // its corner dot carries the connection status; tapping anywhere on the
        // pill opens the feed list, with Dashboard at the bottom of it
        // (the old separate dot opened the dashboard, and sat so close to the
        // feed menu that it was easy to hit by mistake). Folded, only the
        // icon is left, and it opens the same list.
        // No arrangement spacing: each folding piece carries its own gap, so the
        // folded pill closes into a circle around what it keeps.
        Box {
            GlassPill(
                horizontalArrangement = Arrangement.Start,
                modifier = Modifier
                    .clip(CircleShape)
                    .clickable(onClickLabel = "Switch feeds or open the feed dashboard") { feedModeExpanded = true }
                    .semantics { contentDescription = "Feed: ${feedMode.displayName}, $connectionStatus" },
            ) {
                Box(
                    modifier = Modifier.size(30.dp),
                    contentAlignment = Alignment.Center,
                ) {
                    Icon(
                        imageVector = feedMode.icon,
                        contentDescription = null,
                        tint = PrimaryText,
                        modifier = Modifier.size(18.dp),
                    )
                    Box(
                        modifier = Modifier
                            .align(Alignment.BottomEnd)
                            .offset(x = (-1).dp, y = (-1).dp)
                            .size(8.dp)
                            .shadow(3.dp, CircleShape)
                            .clip(CircleShape)
                            .background(dotColor),
                    )
                }

                Box(Modifier.chromeFold(leadingGap = 6.dp)) {
                    Row(verticalAlignment = Alignment.CenterVertically) {
                        Text(
                            text = feedMode.displayName,
                            color = PrimaryText,
                            fontSize = 17.sp,
                            fontWeight = FontWeight.Bold,
                            maxLines = 1,
                        )
                        Spacer(Modifier.width(2.dp))
                        Icon(
                            imageVector = NostrVaultIcons.ChevronDown,
                            contentDescription = null,
                            tint = PrimaryText,
                            modifier = Modifier.size(16.dp),
                        )
                        Spacer(Modifier.width(6.dp))
                    }
                }
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
                        leadingIcon = { Icon(mode.icon, contentDescription = null, modifier = Modifier.size(18.dp)) },
                        trailingIcon = if (mode == feedMode) {
                            { Icon(NostrVaultIcons.Check, contentDescription = "Current feed", modifier = Modifier.size(16.dp)) }
                        } else null,
                        onClick = {
                            onModeChange(mode)
                            feedModeExpanded = false
                        },
                    )
                }
                HorizontalDivider()
                DropdownMenuItem(
                    text = { Text("Dashboard") },
                    leadingIcon = {
                        Box {
                            Icon(NostrVaultIcons.Relay, contentDescription = null, modifier = Modifier.size(18.dp))
                            Box(
                                Modifier
                                    .align(Alignment.BottomEnd)
                                    .size(6.dp)
                                    .clip(CircleShape)
                                    .background(dotColor),
                            )
                        }
                    },
                    onClick = {
                        feedModeExpanded = false
                        onOpenFeedDashboard()
                    },
                )
            }
        }

        // Folded, the floating "New Posts" button becomes a small pill centred
        // in this row, between the two circles (iOS `foldedNewPostsPill`).
        Box(Modifier.weight(1f), contentAlignment = Alignment.Center) {
            if (newPostsCount > 0) {
                val folded by rememberChromeFolded()
                NewPostsPill(
                    count = newPostsCount,
                    compact = true,
                    onClick = onLoadNewPosts,
                    modifier = Modifier.chromeReveal().blockedWhen(!folded),
                )
            }
        }

        // ── Trailing pill: compact toggle + mode-dependent filters.
        // Reels has no layout button, so collapsed there leaves nothing to show.
        AnimatedVisibility(
            visible = !(collapsed && feedMode == FeedMode.REELS),
            enter = fadeIn(Motion.chrome()),
            exit = fadeOut(Motion.chrome()),
        ) { GlassPill(horizontalArrangement = Arrangement.Start) {
            // Layout mode toggle: expanded -> condensed -> threaded -> expanded.
            // Reels is one video per screen — there is no layout to switch.
            if (feedMode != FeedMode.REELS) IconButton(onClick = onCycleLayoutMode, modifier = Modifier.size(40.dp)) {
                val icon = when (layoutMode) {
                    FeedLayoutMode.EXPANDED -> NostrVaultIcons.ExpandedView
                    FeedLayoutMode.CONDENSED -> NostrVaultIcons.CompactView
                    FeedLayoutMode.THREADED -> NostrVaultIcons.ThreadedView
                }
                Icon(
                    imageVector = icon,
                    contentDescription = layoutMode.displayName,
                    tint = if (layoutMode != FeedLayoutMode.EXPANDED) colors.primary else SecondaryText,
                    modifier = Modifier.size(25.dp),
                )
            }

            // Mode-dependent filter buttons. Articles has none: reposts,
            // replies and auto-load are all about kind-1 traffic, and a
            // long-form list is short enough not to need them.
            Box(Modifier.chromeFold(leadingGap = 4.dp).blockedWhen(collapsed)) { Row(verticalAlignment = Alignment.CenterVertically) { when (feedMode) {
                FeedMode.ARTICLES, FeedMode.RECIPES, FeedMode.LIVE -> Unit
                FeedMode.REELS -> {
                    // Following, or everyone behind the sensitive-content warning.
                    IconButton(onClick = onReelsFollowing, modifier = Modifier.size(40.dp)) {
                        Icon(
                            imageVector = if (!reelsGlobal) NostrVaultIcons.People else NostrVaultIcons.PeopleOutline,
                            contentDescription = "Videos from people you follow",
                            tint = if (!reelsGlobal) colors.primary else SecondaryText,
                            modifier = Modifier.size(18.dp),
                        )
                    }
                    IconButton(onClick = onReelsGlobal, modifier = Modifier.size(40.dp)) {
                        Icon(
                            imageVector = if (reelsGlobal) NostrVaultIcons.Globe else NostrVaultIcons.GlobeOutline,
                            contentDescription = "Videos from everyone",
                            tint = if (reelsGlobal) colors.primary else SecondaryText,
                            modifier = Modifier.size(18.dp),
                        )
                    }
                }
                FeedMode.FOLLOWING, FeedMode.DISCOVERY, FeedMode.GLOBAL -> {
                    if (feedMode == FeedMode.GLOBAL) {
                        // Who Global shows, and in which languages (iOS #128/#133).
                        TrustScopeButton(everyone = globalShowsEveryone, onClick = onToggleTrustScope)
                        LanguageFilterButton(selected = globalFeedLanguages, onChange = onSetGlobalLanguages)
                    }
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
                    // Media's Global gets the same Web of Trust / Everyone shield.
                    if (!mediaFollowingOnly) {
                        TrustScopeButton(everyone = globalShowsEveryone, onClick = onToggleTrustScope)
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
            } } }
        } }
    }
}

/**
 * Who Global (and Media's Global) shows: the shield is your Web of Trust, the
 * globe (in orange) is everyone. One button, so the pill keeps its width.
 */
@Composable
private fun TrustScopeButton(everyone: Boolean, onClick: () -> Unit) {
    val colors = LocalNostrVaultColors.current
    IconButton(
        onClick = onClick,
        modifier = Modifier
            .size(32.dp)
            .semantics {
                stateDescription = if (everyone) "Everyone" else "Web of Trust"
            },
    ) {
        Icon(
            imageVector = if (everyone) NostrVaultIcons.Globe else NostrVaultIcons.TrustShield,
            contentDescription = if (everyone) {
                "Everyone: unfiltered posts. Tap for your Web of Trust"
            } else {
                "Web of Trust: people you follow and the people they follow. Tap for everyone"
            },
            tint = if (everyone) ZapOrange else colors.primary,
            modifier = Modifier.size(18.dp),
        )
    }
}

/**
 * Global's language picker. Pick any number of languages; none picked shows
 * every language. The menu stays open between picks so several can be
 * chosen in one go, as on iOS. The device's own languages come first.
 */
@Composable
private fun LanguageFilterButton(selected: List<String>, onChange: (List<String>) -> Unit) {
    val colors = LocalNostrVaultColors.current
    var expanded by remember { mutableStateOf(false) }
    val languages = remember {
        val locales = android.os.LocaleList.getDefault()
        FeedLanguage.pickerList((0 until locales.size()).map { locales[it].toLanguageTag() })
    }
    Box {
        IconButton(
            onClick = { expanded = true },
            modifier = Modifier
                .size(32.dp)
                .semantics { stateDescription = FeedLanguage.summary(selected) },
        ) {
            Icon(
                imageVector = if (selected.isEmpty()) NostrVaultIcons.LanguagesOutline else NostrVaultIcons.Languages,
                contentDescription = "Languages",
                tint = if (selected.isEmpty()) SecondaryText else colors.primary,
                modifier = Modifier.size(18.dp),
            )
        }
        DropdownMenu(
            expanded = expanded,
            onDismissRequest = { expanded = false },
            modifier = Modifier.heightIn(max = 420.dp),
        ) {
            DropdownMenuItem(
                text = { Text("All languages") },
                leadingIcon = {
                    Icon(
                        imageVector = if (selected.isEmpty()) NostrVaultIcons.Check else NostrVaultIcons.GlobeOutline,
                        contentDescription = null,
                        modifier = Modifier.size(18.dp),
                    )
                },
                onClick = { onChange(emptyList()) },
            )
            HorizontalDivider()
            languages.forEach { language ->
                val isOn = language.code in selected
                DropdownMenuItem(
                    text = { Text(language.displayName()) },
                    leadingIcon = {
                        if (isOn) {
                            Icon(NostrVaultIcons.Check, contentDescription = "Selected", modifier = Modifier.size(18.dp))
                        } else {
                            Spacer(Modifier.size(18.dp))
                        }
                    },
                    onClick = {
                        onChange(if (isOn) selected - language.code else selected + language.code)
                    },
                )
            }
        }
    }
}

// ── Empty state ──────────────────────────────────────────────────

// iOS FeedView empty state: thin gradient icon, bold title, monospaced
// subtitle, and a full-width gradient "Refresh Feed" button.
@Composable
private fun EmptyFeedPlaceholder(
    mode: FeedMode,
    onRefresh: (() -> Unit)? = null,
    /// Overrides the per-mode subtitle. Discovery uses it to say which of the
    /// two reasons its feed is empty — see the call site in FeedScreen.
    subtitleOverride: String? = null,
) {
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
                    FeedMode.REELS -> NostrVaultIcons.Reels
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
                    FeedMode.REELS -> "No Videos Yet"
                },
                color = PrimaryText,
                fontSize = 22.sp,
                fontWeight = FontWeight.Bold,
                letterSpacing = 0.2.sp,
            )
            Spacer(Modifier.height(12.dp))
            Text(
                text = subtitleOverride ?: when (mode) {
                    FeedMode.FOLLOWING -> "Follow npubs on Nostr to see their posts here"
                    FeedMode.DISCOVERY -> "Analyzing your extended network..."
                    FeedMode.GLOBAL -> "Waiting for notes from your feed relays"
                    FeedMode.POPULAR -> "Waiting for engagement data to arrive"
                    FeedMode.MEDIA -> "Photos and videos from your feed show up here"
                    FeedMode.ARTICLES -> "Long-form posts in your vault show up here"
                    FeedMode.RECIPES -> "Recipes from zap.cooking show up here"
                    FeedMode.LIVE -> "Streams that are running right now show up here"
                    FeedMode.REELS -> "Videos from your feed show up here"
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
private fun NewPostsPill(
    count: Int,
    onClick: () -> Unit,
    modifier: Modifier = Modifier,
    /** The small "↑ N" pill the folded top bar shows in the button's place. */
    compact: Boolean = false,
) {
    val colors = LocalNostrVaultColors.current
    // Mirrors iOS: Capsule fill(havenPurple/theme primary), white content,
    // soft offset drop shadow (black 40%, radius 8, y+4), 10/20 padding,
    // arrow.up size 12 bold + "N New Posts" size 13 bold. Compact: 5/10
    // padding, radius 4 / y+2 shadow, arrow 11 + count 12 (99+ at most).
    val shape = RoundedCornerShape(50)
    // Tapped anywhere in the box, rippled on the capsule.
    val interaction = remember { MutableInteractionSource() }
    Box(
        modifier = modifier
            .semantics(mergeDescendants = true) { contentDescription = "$count new posts, tap to load" }
            // The small pill's tap target, without growing the pill.
            .clickable(interactionSource = interaction, indication = null, onClick = onClick)
            .padding(if (compact) 8.dp else 0.dp),
    ) {
        Row(
            verticalAlignment = Alignment.CenterVertically,
            modifier = Modifier
                .shadow(
                    elevation = if (compact) 4.dp else 8.dp,
                    shape = shape,
                    ambientColor = Color.Black.copy(alpha = 0.4f),
                    spotColor = Color.Black.copy(alpha = 0.4f),
                )
                .clip(shape)
                .background(colors.primary)
                .indication(interaction, LocalIndication.current)
                .padding(
                    vertical = if (compact) 5.dp else 10.dp,
                    horizontal = if (compact) 10.dp else 20.dp,
                ),
        ) {
            Icon(
                imageVector = NostrVaultIcons.ArrowUp,
                contentDescription = null,
                tint = PrimaryText,
                modifier = Modifier.size(if (compact) 11.dp else 12.dp),
            )
            Spacer(Modifier.width(if (compact) 4.dp else 8.dp))
            Text(
                text = if (compact) (if (count > 99) "99+" else "$count") else "$count New Posts",
                fontWeight = FontWeight.Bold,
                fontSize = if (compact) 12.sp else 13.sp,
                color = PrimaryText,
            )
        }
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

/** Icon for the feed picker and the top bar; matches the iPhone's. */
private val FeedMode.icon: ImageVector
    get() = when (this) {
        FeedMode.FOLLOWING -> NostrVaultIcons.People
        FeedMode.DISCOVERY -> NostrVaultIcons.Discover
        FeedMode.GLOBAL -> NostrVaultIcons.Globe
        FeedMode.POPULAR -> NostrVaultIcons.Popular
        FeedMode.MEDIA -> NostrVaultIcons.Media
        FeedMode.REELS -> NostrVaultIcons.Reels
        FeedMode.ARTICLES -> NostrVaultIcons.Articles
        FeedMode.RECIPES -> NostrVaultIcons.Recipes
        FeedMode.LIVE -> NostrVaultIcons.Live
    }
