package com.nostrvault.ui.screens.feed

import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.material3.*
import androidx.compose.material3.pulltorefresh.PullToRefreshBox
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalClipboardManager
import androidx.compose.ui.unit.dp
import androidx.compose.ui.zIndex
import androidx.hilt.lifecycle.viewmodel.compose.hiltViewModel
import kotlinx.coroutines.flow.filterNotNull
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.withTimeoutOrNull
import kotlinx.coroutines.launch
import com.nostrvault.data.model.FeedLayoutMode
import com.nostrvault.data.model.FeedMode
import com.nostrvault.data.model.ReelsScope
import com.nostrvault.ui.components.ThreadLineAnchor
import com.nostrvault.ui.components.GlassScaffold
import com.nostrvault.ui.components.ScrollCondenseEffect
import com.nostrvault.ui.components.blockedWhen
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
    val canSign = com.nostrvault.ui.components.rememberCanSign()
    val liveStreams by viewModel.liveStreams.collectAsState()
    val liveLoading by viewModel.liveLoading.collectAsState()
    val marketListings by viewModel.marketListings.collectAsState()
    val marketLoading by viewModel.marketLoading.collectAsState()
    val marketCategory by viewModel.marketCategory.collectAsState()
    val marketScope by viewModel.marketScope.collectAsState()
    val marketFollowSetIsEmpty by viewModel.marketFollowSetIsEmpty.collectAsState()
    val marketGlobalWarning by viewModel.marketGlobalWarning.collectAsState()
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
    // Read by the list rows (FeedNoteList), not here: passed as State so only they recompose.
    val unavailableNoteIdsState = viewModel.unavailableNoteIds.collectAsState()
    // Read straight off the ViewModel's snapshot map. Collecting it here would
    // subscribe the whole screen to every metadata batch; each feed row narrows
    // its own read below instead.
    val allProfiles = viewModel.profileState
    val isCompact by viewModel.compactModeEnabled.collectAsState()
    val layoutMode by viewModel.layoutMode.collectAsState()
    val isThreaded by viewModel.threadedModeEnabled.collectAsState()
    val feedThreadsState = viewModel.feedThreads.collectAsState()
    val feedThreads by feedThreadsState
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
    val expandedNote = remember { mutableStateOf<String?>(null) }
    var expandedNoteId by expandedNote
    // Holds a tapped thread line where it was when the open line above closes.
    val threadLineAnchor = remember(listState) { ThreadLineAnchor(scope, listState) }

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

    FeedMissingNotesEffects(notes, viewModel)

    // The sheets and dialogs a row or the toolbar opens (FeedScreenSheets.kt).
    val sheets = remember { FeedSheetState() }
    // Compact and threaded lines open the same avatar menu as a full note.
    val feedAvatarMenu = rememberFeedAvatarMenu(viewModel)
    var openListing by sheets::openListing
    var showFeedMenuEditor by sheets::showFeedMenuEditor
    // Reels' Global scope is unmoderated video from the whole network; it sits
    // behind a warning (iOS parity: the same one Media's Global uses there).
    // Global's Everyone scope sits behind the same warning (iOS parity).
    var showGlobalEveryoneWarning by sheets::showGlobalEveryoneWarning
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

    FeedScrollTrackingEffects(listState, notes, viewModel)

    // A tapped post stays open after the reader scrolls away from it, so what
    // matters is whether its row is still on screen.
    val currentOpenRowKey by rememberUpdatedState(openRowKey(expandedNoteId, isThreaded, feedThreads))
    val openRowShown by remember {
        derivedStateOf {
            val key = currentOpenRowKey ?: return@derivedStateOf false
            listState.layoutInfo.visibleItemsInfo.any { it.key == key }
        }
    }

    // Not while a tapped post is on screen: new posts landing on top would
    // push it off the tap line. They apply once it has scrolled away.
    FeedAutoApplyEffect(
        viewModel,
        pendingCount = { pendingCount },
        autoLoad = { autoLoad && !openRowShown },
        isAtTop = { isAtTop },
    )

    FeedRevealEffect(listState, isThreaded = { isThreaded }, feedThreads = { feedThreads }, notes = { notes }, isAtTop = { isAtTop })

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

    FeedTabEffects(feedMode, viewModel, listState, hashtagsListState, hashtagsViewModel, isAtTop = { isAtTop })

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
    val showNewPosts = showNewPostsPill && pendingCount > 0 && (!autoLoad || !isAtTop || openRowShown) &&
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
            // A read-only sign-in can't sign a post, so it gets no Post.
            if (canSign) FeedPostButton(feedMode = feedMode, modeComposer = modeComposer, meterLift = meterLift, onPost = postAction)
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
                    onPost = if (canSign) ({ onComposeMode(com.nostrvault.ui.screens.ModeComposerKind.DIVINE) }) else null,
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
                    globalWarningPending = marketGlobalWarning,
                    onConfirmGlobal = viewModel::confirmMarketGlobal,
                    onCancelGlobal = viewModel::cancelMarketGlobal,
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
            } else if (notes.isEmpty() && (isRefreshing || (isLoadingFeed && !(feedMode == FeedMode.DISCOVERY && isRelayBooting)))) {
                // Five skeleton rows whenever the feed is loading with nothing
                // to show yet, first load included (iOS FeedView "Loading
                // header"); the empty states wait until loading ends.
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
                        // Someone who has just followed waits for the relay's
                        // next rebuild, not for a follow (iOS waitsForFirstFollow).
                        if (noWebOfTrustYet && followedPubkeys.isEmpty()) {
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
                FeedNoteList(
                    viewModel = viewModel,
                    listState = listState,
                    openRowShown = { openRowShown },
                    padding = padding,
                    meterLift = meterLift,
                    threadLineAnchor = threadLineAnchor,
                    isThreaded = isThreaded,
                    feedThreadsState = feedThreadsState,
                    notes = notes,
                    isCompact = isCompact,
                    allProfiles = allProfiles,
                    expandedNote = expandedNote,
                    threadFolds = threadFolds,
                    unavailableNoteIdsState = unavailableNoteIdsState,
                    isLoadingMore = isLoadingMore,
                    feedAvatarMenu = feedAvatarMenu,
                    sheets = sheets,
                    openProfile = openProfile,
                    onNoteClick = onNoteClick,
                    onArticleClick = onArticleClick,
                    onReply = onReply,
                    onQuote = onQuote,
                    onCompose = onCompose,
                )
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

    FeedScreenSheets(
        sheets = sheets,
        viewModel = viewModel,
        notes = notes,
        allProfiles = allProfiles,
        feedMode = feedMode,
        openProfile = openProfile,
        onProfileClick = onProfileClick,
        onMessageUser = onMessageUser,
    )
}
