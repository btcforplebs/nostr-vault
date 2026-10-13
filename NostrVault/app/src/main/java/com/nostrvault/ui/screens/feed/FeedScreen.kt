package com.nostrvault.ui.screens.feed

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.lazy.grid.items
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.*
import androidx.compose.material3.pulltorefresh.PullToRefreshBox
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.shadow
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.layout.onGloballyPositioned
import androidx.compose.ui.layout.positionInRoot
import androidx.compose.ui.platform.LocalClipboardManager
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.text.font.FontWeight
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
import com.nostrvault.ui.navigation.FloatingButtonRow.floatingRowButton
import com.nostrvault.data.model.FeedLayoutMode
import com.nostrvault.data.model.FeedMenuSettings
import com.nostrvault.data.model.FeedMode
import com.nostrvault.data.model.toNote
import com.nostrvault.data.model.FeedNote
import com.nostrvault.data.model.ReelsScope
import com.nostrvault.ui.navigation.FeedTabPicker
import com.nostrvault.ui.components.CustomZapSheet
import com.nostrvault.ui.components.BroadcastSheet
import com.nostrvault.ui.components.EmojiPickerSheet
import com.nostrvault.ui.components.RankedCompactNoteCard
import com.nostrvault.ui.components.CondensedEngagement
import com.nostrvault.ui.components.TrustWebDialog
import com.nostrvault.ui.components.FeedThreadCard
import com.nostrvault.ui.components.ThreadLineAnchor
import com.nostrvault.ui.components.GlassScaffold
import com.nostrvault.ui.components.UGCReportDialog
import com.nostrvault.ui.components.NostrMentions
import com.nostrvault.ui.components.ScrollCondenseEffect
import com.nostrvault.ui.components.blockedWhen
import com.nostrvault.ui.components.chromeFab
import com.nostrvault.ui.components.newPostsFold
import com.nostrvault.ui.components.rememberChromeFolded
import com.nostrvault.ui.components.SkeletonFeed
import com.nostrvault.ui.theme.*
import com.nostrvault.service.FeedLanguage

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
    /** Opens a DM with a pubkey, its box prefilled (Message seller). */
    onMessageUser: (pubkey: String, draft: String) -> Unit = { _, _ -> },
    onCompose: () -> Unit,
    /** Opens the diVine, article or recipe composer. */
    onComposeMode: (com.nostrvault.ui.screens.ModeComposerKind) -> Unit = {},
    /** Opens the composer with [text] filled in (Share a song to Nostr). */
    onComposeText: (String) -> Unit = {},
    onReply: ((String) -> Unit)? = null,
    onQuote: ((String) -> Unit)? = null,
    /** Opens the feed dashboard (feed menu > Dashboard). */
    onOpenDashboard: () -> Unit = {},
    viewModel: FeedViewModel = hiltViewModel(),
    hashtagsViewModel: HashtagsFeedViewModel = hiltViewModel(),
) {
    val feedMode by viewModel.feedMode.collectAsState()
    // Fill your feed: while its meter is up, a tapped person opens the small
    // profile card (look before you follow), Post rises above the open meter
    // and the feed's end scrolls clear of it.
    val guidePhase by com.nostrvault.vaultguide.FillYourVaultCoordinator.phase.collectAsState()
    val guideMeterOn by com.nostrvault.vaultguide.FillYourVaultCoordinator.meterOn.collectAsState()
    val guideCollapsed by com.nostrvault.vaultguide.FillYourVaultCoordinator.meterCollapsed.collectAsState()
    val guideMeterHeight by com.nostrvault.vaultguide.FillYourVaultCoordinator.meterHeight.collectAsState()
    val guideMeterShowing = com.nostrvault.vaultguide.FillYourFeedGuide.showsMeter(guidePhase, guideMeterOn)
    val meterLift = if (guideMeterShowing && !guideCollapsed && guideMeterHeight > 0.dp) guideMeterHeight + 10.dp else 0.dp
    val openProfile: (String) -> Unit = { pubkey ->
        if (com.nostrvault.vaultguide.FillYourFeedGuide.opensProfileCard(guideMeterShowing)) {
            com.nostrvault.vaultguide.FillYourVaultCoordinator.profileCardPubkey.value = pubkey
        } else {
            onProfileClick(pubkey)
        }
    }
    // The Feeds tutorial starts here the first time the feed shows (after
    // Fill your vault; see TutorialProgress). Its cards point at the picker.
    // Re-checked when a status is saved, so an account whose Fill your vault
    // is marked done after its follow list loads gets Feeds in this launch.
    val activeHex by viewModel.activeHexPubkey.collectAsState()
    val tutorialRevision by com.nostrvault.tutorials.TutorialCenter.revision.collectAsState()
    LaunchedEffect(activeHex, tutorialRevision) {
        com.nostrvault.tutorials.TutorialCenter.startIfEligible(com.nostrvault.tutorials.TutorialID.FEEDS, activeHex)
    }
    // Hashtags keeps its own list: its rows are not the note list's.
    val hashtagsListState = rememberLazyListState()
    // The post button writes what the feed shows: a diVine in diVines, an
    // article in Articles, a recipe in Recipes, a note everywhere else.
    val modeComposer = when (feedMode) {
        FeedMode.REELS -> com.nostrvault.ui.screens.ModeComposerKind.DIVINE
        FeedMode.ARTICLES -> com.nostrvault.ui.screens.ModeComposerKind.ARTICLE
        FeedMode.RECIPES -> com.nostrvault.ui.screens.ModeComposerKind.RECIPE
        FeedMode.MARKETPLACE -> com.nostrvault.ui.screens.ModeComposerKind.LISTING
        FeedMode.POLLS -> com.nostrvault.ui.screens.ModeComposerKind.POLL
        else -> null
    }
    val postAction: () -> Unit = { modeComposer?.let(onComposeMode) ?: onCompose() }
    val liveStreams by viewModel.liveStreams.collectAsState()
    val liveLoading by viewModel.liveLoading.collectAsState()
    val marketListings by viewModel.marketListings.collectAsState()
    val marketLoading by viewModel.marketLoading.collectAsState()
    val marketCategory by viewModel.marketCategory.collectAsState()
    val marketScope by viewModel.marketScope.collectAsState()
    val marketFollowSetIsEmpty by viewModel.marketFollowSetIsEmpty.collectAsState()
    val notes by viewModel.filteredNotes.collectAsState()
    val mediaNotes by viewModel.mediaNotes.collectAsState()
    val isRefreshing by viewModel.isRefreshing.collectAsState()
    val isRelayImporting by viewModel.isRelayImporting.collectAsState()
    val relayImportStatus by viewModel.relayImportStatus.collectAsState()
    val isLoadingMore by viewModel.isLoadingMore.collectAsState()
    val connectionStatus by viewModel.connectionStatus.collectAsState()
    val isLoadingExtendedNetwork by viewModel.isLoadingExtendedNetwork.collectAsState()
    val isLoadingPopular by viewModel.isLoadingPopular.collectAsState()
    val isLoadingFeed by viewModel.isLoadingFeed.collectAsState()
    val isLoadingContacts by viewModel.isLoadingContacts.collectAsState()
    val hasAttemptedContactLoad by viewModel.hasAttemptedContactLoad.collectAsState()
    val hasAnyNotes by viewModel.hasNotes.collectAsState()
    val isRelayBooting by viewModel.isRelayBooting.collectAsState()
    val relayBootStatus by viewModel.relayBootStatus.collectAsState()
    val feedRelaysUnreachable by viewModel.feedRelaysUnreachable.collectAsState()
    val liveLoadFailed by viewModel.liveLoadFailed.collectAsState()
    val liveFollowSetIsEmpty by viewModel.liveFollowSetIsEmpty.collectAsState()
    val liveGlobalGate by viewModel.liveGlobalGate.collectAsState()
    val marketLoadFailed by viewModel.marketLoadFailed.collectAsState()
    val followedPubkeys by viewModel.followedPubkeys.collectAsState()
    val unavailableNoteIds by viewModel.unavailableNoteIds.collectAsState()
    // Read straight off the ViewModel's snapshot map. Collecting it here would
    // subscribe the whole screen to every metadata batch; each feed row narrows
    // its own read below instead.
    val allProfiles = viewModel.profileState
    val isCompact by viewModel.compactModeEnabled.collectAsState()
    val layoutMode by viewModel.layoutMode.collectAsState()
    val isThreaded by viewModel.threadedModeEnabled.collectAsState()
    val feedThreads by viewModel.feedThreads.collectAsState()
    val autoLoad by viewModel.autoLoadEnabled.collectAsState()
    val showNewPostsPill by viewModel.showNewPostsPill.collectAsState()
    val showReposts by viewModel.showReposts.collectAsState()
    val showReplies by viewModel.showReplies.collectAsState()
    val mediaFollowingOnly by viewModel.mediaFollowingOnly.collectAsState()
    val articlesScope by viewModel.articlesScope.collectAsState()
    val recipesScope by viewModel.recipesScope.collectAsState()
    val pollsScope by viewModel.pollsScope.collectAsState()
    val pollStatus by viewModel.pollStatus.collectAsState()
    val liveScope by viewModel.liveScope.collectAsState()
    val popularFilter by viewModel.popularFilter.collectAsState()
    val globalShowsEveryone by viewModel.globalShowsEveryone.collectAsState()
    val globalFeedLanguages by viewModel.globalFeedLanguages.collectAsState()
    val trustGraphReady by viewModel.trustGraphReady.collectAsState()
    val noWebOfTrustYet by viewModel.noWebOfTrustYet.collectAsState()
    val showEngagementStats by viewModel.showEngagementStats.collectAsState()
    val pendingCount by viewModel.pendingNoteCount.collectAsState()
    // The parent, quote and repost caches are not collected here. Every parent
    // or quote that resolves replaces those maps, and a read at this level
    // re-ran this whole screen and handed every visible row a new map to
    // compare — dozens of times while a page of replies streams in. Each row
    // subscribes to just its own entries in FeedFullNoteRow instead.
    val listState = rememberLazyListState()
    val clipboard = LocalClipboardManager.current
    val scope = rememberCoroutineScope()

    // Inline expansion state for compact mode (iOS parity: tap expands inline first).
    // Threaded mode's cards share this same field rather than keeping their own —
    // one selection across both condensed layouts, and it survives a card being
    // recycled off-screen and back by a LazyColumn (per-card `remember` would not).
    var expandedNoteId by remember { mutableStateOf<String?>(null) }
    // Holds a tapped thread line where it was when the open line above closes.
    val threadLineAnchor = remember(listState) { ThreadLineAnchor(scope, listState) }
    val density = LocalDensity.current

    // Per-thread "show more replies" fold, hoisted for the same reason: a
    // LazyColumn item's own `remember` is dropped when it scrolls out of view.
    val threadFolds = remember { mutableStateMapOf<String, Boolean>() }

    // An artist or album opened from the full player on another feed:
    // the Music feed comes up with the page open.
    val musicReveal by com.nostrvault.ui.screens.music.MusicFeedState.revealRequested.collectAsState()
    LaunchedEffect(musicReveal) {
        if (!musicReveal) return@LaunchedEffect
        com.nostrvault.ui.screens.music.MusicFeedState.consumeReveal()
        if (feedMode != FeedMode.MUSIC) viewModel.setFeedMode(FeedMode.MUSIC)
    }

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
            // The fetch below first looks the ids up in the feed (iOS #302);
            // building that index here keeps a 10k-note pass off Main.
            viewModel.warmNoteIndex()
            notes.flatMap { note ->
                // A bare repost's row shows the note it points at.
                listOfNotNull(note.parentEventId, note.repostedEventId?.takeIf { note.isBareRepost })
                    .filter { viewModel.parentNoteFor(it) == null }
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
    var showNoLightningAddress by remember { mutableStateOf(false) }
    val zapSheetState = rememberModalBottomSheetState(skipPartiallyExpanded = true)

    // More menu / delete confirmation state
    var deleteNoteId by remember { mutableStateOf<String?>(null) }
    var reportNoteId by remember { mutableStateOf<String?>(null) }
    var blockNoteId by remember { mutableStateOf<String?>(null) }

    // Emoji picker state
    var emojiPickerNoteId by remember { mutableStateOf<String?>(null) }
    val emojiSheetState = rememberModalBottomSheetState(skipPartiallyExpanded = true)

    // Broadcast sheet state
    var broadcastNoteId by remember { mutableStateOf<String?>(null) }
    // The post bar's Web of Trust button: the author whose map is open.
    var trustWebAuthor by remember { mutableStateOf<String?>(null) }
    // Compact and threaded lines open the same avatar menu as a full note.
    val feedAvatarMenu = rememberFeedAvatarMenu(viewModel)
    var openListing by remember { mutableStateOf<com.nostrvault.data.model.MarketListing?>(null) }
    var listingInfoNote by remember { mutableStateOf<FeedNote?>(null) }
    val broadcastSheetState = rememberModalBottomSheetState(skipPartiallyExpanded = true)

    var showFeedMenuEditor by remember { mutableStateOf(false) }

    // Reels' Global scope is unmoderated video from the whole network; it sits
    // behind a warning (iOS parity: the same one Media's Global uses there).
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

    // Hold-the-Feed-tab picker (iOS #239): it shows this feed's mode and
    // hands its pick here, where the mode lives.
    LaunchedEffect(feedMode) { FeedTabPicker.shownMode = feedMode }
    LaunchedEffect(Unit) {
        FeedTabPicker.request.filterNotNull().collect { mode ->
            FeedTabPicker.request.value = null
            if (mode != viewModel.feedMode.value) viewModel.setFeedMode(mode)
        }
    }

    // Handle tab re-selection: scroll to top or refresh if already at top
    LaunchedEffect(Unit) {
        viewModel.scrollToTopRequest.collect {
            // Reels has no list to scroll, and the untouched list below it
            // always reads as "at top" — a reselect must not wipe the viewer's
            // place by refreshing.
            if (viewModel.feedMode.value == FeedMode.REELS) return@collect
            if (viewModel.feedMode.value == FeedMode.HASHTAGS) {
                if (hashtagsListState.firstVisibleItemIndex == 0 && hashtagsListState.firstVisibleItemScrollOffset == 0) {
                    hashtagsViewModel.reload()
                } else {
                    hashtagsListState.scrollToItem(0)
                }
                return@collect
            }
            if (isAtTop) {
                viewModel.refresh()
            } else {
                listState.scrollToItem(0) // Instant scroll for better performance
            }
        }
    }

    // Posts are waiting and either auto-load is off or the user has scrolled
    // away from the top. Never with the pill switched off in Appearance.
    // Reels, Live, Marketplace, Music and Hashtags are not views of the note list; the
    // note subscription keeps filling `pending` underneath them, so a pill
    // there would offer posts that cannot show (same fix as iPhone #237).
    val scopeGlobal = when (feedMode) {
        FeedMode.MEDIA -> !mediaFollowingOnly
        FeedMode.ARTICLES -> articlesScope == com.nostrvault.data.model.MediaFeedMode.GLOBAL
        FeedMode.RECIPES -> recipesScope == com.nostrvault.data.model.MediaFeedMode.GLOBAL
        FeedMode.POLLS -> pollsScope == com.nostrvault.data.model.MediaFeedMode.GLOBAL
        FeedMode.LIVE -> liveScope == ReelsScope.GLOBAL
        FeedMode.MARKETPLACE -> marketScope == ReelsScope.GLOBAL
        FeedMode.REELS -> reelsScope == ReelsScope.GLOBAL
        else -> false
    }
    // iOS FeedView.rootContentBase: a feed asked of your follow set has nothing
    // to show until that set is known, and "you follow nobody" needs a
    // finished contact load behind it (FollowingFeedState).
    val isFollowSetFeed = feedMode == FeedMode.FOLLOWING ||
        (!scopeGlobal && feedMode in setOf(FeedMode.ARTICLES, FeedMode.POLLS, FeedMode.MEDIA))
    val followPlaceholder = followingFeedPlaceholder(
        followCount = followedPubkeys.size,
        hasAttemptedContactLoad = hasAttemptedContactLoad,
        isLoadingContacts = isLoadingContacts,
        isLoadingFeed = isLoadingFeed,
        hasNotes = hasAnyNotes,
    )
    val showNewPosts = showNewPostsPill && pendingCount > 0 && (!autoLoad || !isAtTop) &&
        feedMode !in setOf(FeedMode.REELS, FeedMode.LIVE, FeedMode.MARKETPLACE, FeedMode.MUSIC, FeedMode.HASHTAGS)
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
                layoutMode = layoutMode,
                autoLoad = autoLoad,
                showReposts = showReposts,
                showReplies = showReplies,
                popularFilter = popularFilter,
                showEngagementStats = showEngagementStats,
                globalShowsEveryone = globalShowsEveryone,
                globalFeedLanguages = globalFeedLanguages,
                // Reads the setting at tap time; leaving the Web of Trust
                // goes through the warning (the only one), coming back does not.
                onToggleTrustScope = {
                    if (viewModel.globalShowsEveryone.value) viewModel.setGlobalShowsEveryone(false)
                    else showGlobalEveryoneWarning = true
                },
                onSetGlobalLanguages = viewModel::setGlobalFeedLanguages,
                scopeGlobal = scopeGlobal,
                onScopeFollowing = { viewModel.setScope(feedMode, global = false) },
                onScopeGlobal = { viewModel.setScope(feedMode, global = true) },
                pollStatus = pollStatus,
                onSetPollStatus = viewModel::setPollStatus,
                onModeChange = viewModel::setFeedMode,
                onCycleLayoutMode = {
                    layoutAnchor = captureLayoutAnchor()?.let { it to layoutMode }
                    viewModel.cycleLayoutMode()
                },
                onToggleAutoLoad = viewModel::toggleAutoLoad,
                onToggleReposts = viewModel::toggleShowReposts,
                onToggleReplies = viewModel::toggleShowReplies,
                onSetPopularFilter = viewModel::setPopularFilter,
                onToggleEngagementStats = viewModel::toggleShowEngagementStats,
                onEditFeeds = { showFeedMenuEditor = true },
                onOpenDashboard = onOpenDashboard,
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
            if (feedMode != FeedMode.REELS) Box(Modifier.chromeFab().blockedWhen(folded).padding(bottom = meterLift)) {
                // iOS-style gradient "Post" capsule (FeedView compose FAB)
                val colors = LocalNostrVaultColors.current
                Surface(
                    onClick = postAction,
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
                                com.nostrvault.ui.screens.ModeComposerKind.LISTING -> NostrVaultIcons.Marketplace
                                else -> NostrVaultIcons.Compose
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
            // Hashtags shows its own spinner; the note list's refresh is not its.
            isRefreshing = isRefreshing && feedMode != FeedMode.HASHTAGS,
            onRefresh = { if (feedMode == FeedMode.HASHTAGS) hashtagsViewModel.reload() else viewModel.refresh() },
            modifier = Modifier.fillMaxSize(),
        ) {
            if (feedMode == FeedMode.REELS) {
                ReelsFeed(
                    viewModel = viewModel,
                    profiles = allProfiles,
                    topInset = padding.calculateTopPadding(),
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
                    onShowGlobal = { viewModel.setScope(FeedMode.REELS, global = true) },
                )
            } else if (feedMode == FeedMode.MUSIC) {
                com.nostrvault.ui.screens.music.MusicScreen(
                    actions = com.nostrvault.ui.screens.music.MusicActions(
                        onShare = onComposeText,
                        onOpenProfile = onProfileClick,
                        npubToHex = viewModel::npubToHex,
                        followedPubkeys = { viewModel.followedPubkeys.value.toSet() },
                        blockedPubkeys = viewModel.blockedPubkeys,
                    ),
                    contentPadding = padding,
                )
            } else if (feedMode == FeedMode.HASHTAGS) {
                HashtagsFeed(
                    viewModel = hashtagsViewModel,
                    listState = hashtagsListState,
                    contentPadding = PaddingValues(
                        top = padding.calculateTopPadding(),
                        bottom = padding.calculateBottomPadding() + meterLift,
                    ),
                    layoutMode = layoutMode,
                    onNoteClick = onNoteClick,
                    onArticleClick = onArticleClick,
                    onProfileClick = openProfile,
                    onReply = onReply ?: { _ -> onCompose() },
                    onQuote = onQuote ?: {},
                    // Not in the feed's note list; register the note so the
                    // thread and compose screens resolve it by id, as Reels does.
                    onCacheNote = viewModel::cacheNote,
                )
            } else if (feedMode == FeedMode.MARKETPLACE) {
                MarketplaceGrid(
                    listings = marketListings,
                    selectedCategory = marketCategory,
                    profiles = allProfiles,
                    isLoading = marketLoading,
                    contentPadding = padding,
                    onSelectCategory = viewModel::selectMarketCategory,
                    onListingClick = { openListing = it },
                    onRefresh = viewModel::refreshMarketplace,
                    onNeedProfiles = viewModel::fetchMissingProfiles,
                    onAppear = viewModel::loadMarketplaceIfNeeded,
                    followSetIsEmpty = marketFollowSetIsEmpty,
                    loadFailed = marketLoadFailed,
                    scopeFollowing = !scopeGlobal,
                    onShowGlobal = { viewModel.setScope(FeedMode.MARKETPLACE, global = true) },
                )
            } else if (feedMode == FeedMode.LIVE) {
                LiveGrid(
                    streams = liveStreams,
                    profiles = allProfiles,
                    isLoading = liveLoading,
                    contentPadding = padding,
                    // The tapped stream is handed over whole rather than looked
                    // up again by id: a kind-30311 event is replaceable and
                    // short-lived, so the copy the grid was showing is the one
                    // to play. LiveStreamHost draws the player over the app.
                    onStreamClick = { com.nostrvault.ui.components.LiveStreamRouter.open(it) },
                    onRefresh = viewModel::refreshLive,
                    loadFailed = liveLoadFailed,
                    scopeFollowing = !scopeGlobal,
                    onShowGlobal = { viewModel.setScope(FeedMode.LIVE, global = true) },
                    followSetIsEmpty = liveFollowSetIsEmpty,
                    globalGate = liveGlobalGate,
                )
            } else if (!hasAnyNotes && isRelayImporting) {
                // The relay is busy importing ("Keep it running"), so nothing
                // loads until it's back. iOS FeedView.importingFeedView.
                ImportingFeedPlaceholder(relayImportStatus)
            } else if (isFollowSetFeed && followPlaceholder == FollowingFeedPlaceholder.LOADING) {
                // iOS loadingContactsView.
                FeedLoadingPlaceholder("Synchronizing", "fetching your follows", "This may take a moment")
            } else if (feedMode == FeedMode.DISCOVERY && isLoadingExtendedNetwork && notes.isEmpty()) {
                // iOS loadingExtendedNetworkView.
                FeedLoadingPlaceholder("Analyzing Network", "finding mutual connections", "This may take a moment")
            } else if (feedMode == FeedMode.POPULAR && isLoadingPopular && notes.isEmpty()) {
                // iOS loadingPopularView.
                FeedLoadingPlaceholder(
                    "Finding Popular Notes",
                    "scoring engagement across relays",
                    "Analyzing reactions, reposts, and zaps",
                )
            } else if (isFollowSetFeed && followPlaceholder == FollowingFeedPlaceholder.EMPTY) {
                // iOS emptyStateView: while the relay boots, say that rather
                // than asking someone to follow people.
                if (isRelayBooting) {
                    RelayStartingPlaceholder(relayBootStatus)
                } else {
                    EmptyFeedPlaceholder(FeedMode.FOLLOWING, onRefresh = viewModel::refresh)
                }
            } else if (feedMode == FeedMode.ARTICLES || feedMode == FeedMode.RECIPES) {
                ArticleList(
                    mode = feedMode,
                    notes = notes,
                    profiles = allProfiles,
                    isRefreshing = isRefreshing,
                    contentPadding = padding,
                    onArticleClick = onArticleClick,
                    onRefresh = viewModel::refresh,
                    scopeFollowing = !scopeGlobal,
                    onShowGlobal = { viewModel.setScope(feedMode, global = true) },
                    loadFailed = feedMode == FeedMode.RECIPES && feedRelaysUnreachable && !isLoadingFeed,
                )
            } else if (feedMode == FeedMode.MEDIA) {
                MediaFeedGrid(
                    notes = mediaNotes,
                    scopeFollowing = !scopeGlobal,
                    isRefreshing = isRefreshing,
                    isLoadingMore = isLoadingMore,
                    contentPadding = padding,
                    onNoteClick = onNoteClick,
                    onLoadMore = viewModel::loadMore,
                )
            } else if (notes.isEmpty() && isRefreshing) {
                // Shimmer skeleton loading
                SkeletonFeed(count = 5)
            } else if (notes.isEmpty() && feedMode == FeedMode.POLLS) {
                // iOS PollsEmptyStateView: the title follows the status filter,
                // and the button posts a poll rather than refreshing.
                EmptyFeedPlaceholder(
                    feedMode,
                    onRefresh = postAction,
                    titleOverride = when (pollStatus) {
                        com.nostrvault.data.model.PollStatusFilter.ALL -> "No polls yet"
                        com.nostrvault.data.model.PollStatusFilter.OPEN -> "No open polls"
                        com.nostrvault.data.model.PollStatusFilter.CLOSED -> "No closed polls"
                    },
                    subtitleOverride = if (scopeGlobal) "Polls from across Nostr show up here"
                    else "Polls from people you follow show up here",
                    actionLabel = "Post a poll",
                )
            } else if (notes.isEmpty() && feedMode == FeedMode.DISCOVERY && isRelayBooting) {
                // iOS emptyDiscoveryStateView while the relay boots.
                RelayStartingPlaceholder(relayBootStatus)
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
                            "Follow more people on Nostr to build your extended network"
                        } else {
                            "No follow lists came back from your relays \u2014 try refreshing"
                        }
                    } else if (feedMode == FeedMode.GLOBAL && !globalShowsEveryone && !trustGraphReady) {
                        // Global fails closed without the trust graph; say so
                        // rather than "waiting for notes" over a full inbox.
                        if (noWebOfTrustYet) {
                            "Follow people to build your web of trust"
                        } else {
                            "Building your Web of Trust\u2026 Tap the shield to see everyone"
                        }
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
                        bottom = padding.calculateBottomPadding() + 88.dp + meterLift,
                    ),
                    modifier = Modifier
                        .fillMaxSize()
                        .onGloballyPositioned {
                            threadLineAnchor.viewportTop = it.positionInRoot().y +
                                with(density) { padding.calculateTopPadding().toPx() }
                        },
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
                                onProfileClick = openProfile,
                                avatarMenu = feedAvatarMenu,
                                onTrustWeb = { author -> trustWebAuthor = author },
                                onOpenThread = { note -> onNoteClick(note.id) },
                                onFetchMissingNote = viewModel::fetchMissingNote,
                                rootUnavailable = thread.rootId in unavailableNoteIds,
                                lineAnchor = threadLineAnchor,
                                bareRepostDisplay = { note -> rememberBareRepostDisplay(note, viewModel) },
                                // iOS: 12pt sides in threaded mode, 12pt between rows.
                                modifier = Modifier.padding(horizontal = 12.dp, vertical = 6.dp),
                                expandedRow = { note, _ ->
                                    FeedFullNoteRow(
                                        note = note,
                                        viewModel = viewModel,
                                        allProfiles = allProfiles,
                                        onNoteClick = onNoteClick,
                                        onArticleClick = onArticleClick,
                                        onProfileClick = openProfile,
                                        onReply = onReply ?: { _ -> onCompose() },
                                        onQuote = onQuote ?: {},
                                        onZap = viewModel::quickZap,
                                        onLongPressZap = { id -> zapNoteId = id },
                                        onNoLightningAddress = { showNoLightningAddress = true },
                                        onBroadcast = { id -> broadcastNoteId = id },
                                        onTrustWeb = { author -> trustWebAuthor = author },
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
                            val (shownNote, repostPlaceholder) = rememberBareRepostDisplay(note, viewModel)
                            val shownPubkeys = remember(headPubkeys, shownNote.pubkey, shownNote.content) {
                                (headPubkeys + shownNote.pubkey + NostrMentions.mentionedPubkeys(shownNote.content)).distinct()
                            }
                            // derivedStateOf, not a plain read: the computation re-runs on
                            // every metadata batch, but this row only recomposes when one of
                            // *its* profiles actually changed. Reading allProfiles directly
                            // here would rebuild every visible card per batch instead.
                            val cardProfiles by remember(shownPubkeys) {
                                derivedStateOf { shownPubkeys.resolveAgainst(allProfiles) }
                            }
                            // Same derivedStateOf reasoning: only this row's stats recompose it.
                            val zapsOnly = LocalZapsOnlyMode.current
                            val statsState = viewModel.noteStats.collectAsState()
                            val engagement by remember(note.id, zapsOnly) {
                                derivedStateOf {
                                    val stats = statsState.value[note.effectiveEventId]
                                    CondensedEngagement(
                                        reactions = if (zapsOnly) 0 else stats?.reactions ?: 0,
                                        reposts = stats?.reposts ?: 0,
                                    )
                                }
                            }
                            RankedCompactNoteCard(viewModel.popularRanks, rankId = note.id,
                                note = shownNote,
                                profile = cardProfiles[shownNote.pubkey],
                                profiles = cardProfiles,
                                repostPlaceholder = repostPlaceholder,
                                // Read once the original has resolved, which is what recomposes this row.
                                repostedOriginal = note.repostedEventId
                                    ?.takeIf { note.isBareRepost && repostPlaceholder == null }
                                    ?.let { viewModel.parentNotesCache.value[it] },
                                engagement = engagement,
                                onNoteClick = { id ->
                                    // Expand inline first instead of navigating
                                    expandedNoteId = id
                                },
                                onProfileClick = openProfile,
                                avatarMenu = feedAvatarMenu,
                                onTrustWeb = { author -> trustWebAuthor = author },
                                // iOS: 8pt sides for a compact row, 12pt between rows.
                                modifier = Modifier.padding(horizontal = 8.dp, vertical = 6.dp),
                            )
                        } else {
                            FeedFullNoteRow(
                                note = note,
                                viewModel = viewModel,
                                allProfiles = allProfiles,
                                onNoteClick = onNoteClick,
                                onArticleClick = onArticleClick,
                                onProfileClick = openProfile,
                                onReply = onReply ?: { _ -> onCompose() },
                                onQuote = onQuote ?: {},
                                onZap = viewModel::quickZap,
                                onLongPressZap = { id -> zapNoteId = id },
                                onNoLightningAddress = { showNoLightningAddress = true },
                                onBroadcast = { id -> broadcastNoteId = id },
                                onTrustWeb = { author -> trustWebAuthor = author },
                                onReport = { id -> reportNoteId = id },
                                onBlock = { id -> blockNoteId = id },
                                onDelete = { id -> deleteNoteId = id },
                                onLongPressLike = { id -> emojiPickerNoteId = id },
                                // iOS: 16pt sides, 12pt between rows.
                                modifier = Modifier.padding(horizontal = 16.dp, vertical = 6.dp),
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
            // Fill your feed: its cards, the meter on Post's row, the profile card.
            val guideFollows by viewModel.feedServiceRef.followedPubkeys.collectAsState()
            com.nostrvault.vaultguide.FillYourFeedOverlay(
                profiles = allProfiles,
                bottomInset = com.nostrvault.ui.navigation.FloatingButtonRow.rowBottom,
                isFollowing = { it in guideFollows },
                onToggleFollow = { viewModel.toggleFollowFromGuide(it) },
                onUnfollow = { viewModel.unfollowFromGuide(it) },
                loadProfileCard = { viewModel.loadProfileCard(it) },
                onOpenFullProfile = onProfileClick,
            )
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



    if (showNoLightningAddress) {
        AlertDialog(
            onDismissRequest = { showNoLightningAddress = false },
            title = { Text("No Lightning Address") },
            text = { Text("This user hasn't configured a lightning address, so they can't receive zaps.") },
            confirmButton = {
                TextButton(onClick = { showNoLightningAddress = false }) { Text("OK") }
            },
        )
    }

    // Custom zap sheet (long-press on the bolt)
    if (zapNoteId != null) {
        CustomZapSheet(
            sheetState = zapSheetState,
            defaultAmount = viewModel.configStoreRef.config.value.defaultZapAmount,
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
                    reportTarget.effectiveAuthor,
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
                        viewModel.blockUser(blockTarget.effectiveAuthor)
                        blockNoteId = null
                    },
                ) { Text("Block", color = ErrorRed) }
            },
            dismissButton = {
                TextButton(onClick = { blockNoteId = null }) { Text("Cancel") }
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
    val broadcastNote = broadcastNoteId?.let { id -> notes.find { it.id == id || it.effectiveEventId == id } }
    if (broadcastNote != null) {
        BroadcastSheet(
            note = broadcastNote,
            sheetState = broadcastSheetState,
            feedService = viewModel.feedServiceRef,
            nostrService = viewModel.nostrServiceRef,
            configStore = viewModel.configStoreRef,
            onDismiss = { broadcastNoteId = null },
            onProfileClick = { broadcastNoteId = null; openProfile(it) },
        )
    }

    trustWebAuthor?.let { author ->
        TrustWebDialog(
            author = author,
            initialPath = null,
            onProfileClick = openProfile,
            onDismiss = { trustWebAuthor = null },
        )
    }

    openListing?.let { listing ->
        MarketListingSheet(
            listing = listing,
            seller = allProfiles[listing.pubkey],
            onOpenSeller = { pubkey -> openListing = null; onProfileClick(pubkey) },
            onMessageSeller = { openListing = null; onMessageUser(it.pubkey, it.messageToSeller) },
            onEventInfo = { openListing = null; listingInfoNote = it.toNote() },
            onDismiss = { openListing = null },
        )
    }
    // Event Info for a listing: listings are not in `notes`, so the feed's
    // broadcast sheet above cannot find them by id.
    listingInfoNote?.let { note ->
        BroadcastSheet(
            note = note,
            sheetState = broadcastSheetState,
            feedService = viewModel.feedServiceRef,
            nostrService = viewModel.nostrServiceRef,
            configStore = viewModel.configStoreRef,
            onDismiss = { listingInfoNote = null },
            onProfileClick = { listingInfoNote = null; openProfile(it) },
        )
    }

    // Edit Feeds: show, hide and reorder the feed picker's feeds (iOS #303).
    if (showFeedMenuEditor) {
        FeedMenuEditor(
            // Hiding the feed you're on would leave the picker without it.
            onSaved = { hidden -> if (feedMode in hidden) viewModel.setFeedMode(FeedMenuSettings.PINNED) },
            onDismiss = { showFeedMenuEditor = false },
        )
    }
}
