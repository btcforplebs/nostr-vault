package com.nostrvault.ui.screens.profile

import com.nostrvault.ui.components.NostrWebLinks
import com.nostrvault.ui.notification.LocalNotificationManager
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.combinedClickable
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.lazy.itemsIndexed
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.foundation.pager.rememberPagerState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.layout.layout
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.ui.platform.LocalClipboardManager
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.AnnotatedString
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.hilt.navigation.compose.hiltViewModel
import coil.compose.AsyncImage
import com.nostrvault.ui.components.AvatarImage
import com.nostrvault.ui.components.GlassPill
import com.nostrvault.ui.components.GlassScaffold
import com.nostrvault.ui.components.NostrContentText
import com.nostrvault.ui.components.NoteCard
import com.nostrvault.ui.components.TrustWebDialog
import com.nostrvault.ui.theme.*

/**
 * User profile screen — ports iOS ProfileView: header + status badge, bio,
 * link chips, follow counts, action row, section tabs with counts, infinite
 * scroll, a media grid, and a full-screen media viewer. On your own profile,
 * pulling the page down opens Edit Profile (iOS #456).
 */
@OptIn(ExperimentalMaterial3Api::class, androidx.compose.foundation.ExperimentalFoundationApi::class)
@Composable
fun ProfileScreen(
    pubkey: String,
    onNoteClick: (String) -> Unit,
    /** Where a quoted long-form post opens; the note screen would show its Markdown source. */
    onArticleClick: (String) -> Unit,
    onProfileClick: (String) -> Unit,
    onReply: (String) -> Unit = {},
    onQuote: (String) -> Unit = {},
    onNavigateToDMThread: (String) -> Unit = {},
    /** Opens a DM with a pubkey, its box prefilled (Message seller). */
    onMessageUser: (pubkey: String, draft: String) -> Unit = { pk, _ -> onNavigateToDMThread(pk) },
    onNavigateToSettings: () -> Unit = {},
    /** Opens the Lightning wallet (own profile's bolt button, as on iOS). */
    onOpenLightning: () -> Unit = {},
    /** Opens the Sell composer (own profile, Shop tab). */
    onSell: () -> Unit = {},
    /** Opens the composer with text in it (sharing a song from the Music tab). */
    onComposeText: (String) -> Unit = {},
    /** Opens the Following / Followers lists on a tab, with the follower count shown here. */
    onOpenFollowList: (FollowListTab, Int?) -> Unit = { _, _ -> },
    /** The note composer: the Profile tab's floating Post button. */
    onCompose: () -> Unit = {},
    /** Leaves this page for the Profile tab: your own profile opened from a note. */
    onOpenMyProfile: () -> Unit = {},
    onBack: () -> Unit,
    /** The Profile tab, as opposed to a profile pushed from a note or a list.
     *  Only the tab goes without a back button; your own profile pushed from a
     *  note gets one (iOS opens it as a sheet with a close button). */
    isTab: Boolean = false,
    viewModel: ProfileViewModel = hiltViewModel(),
    editViewModel: ProfileEditViewModel = hiltViewModel(),
    /** Deletes your own Blossom files from the Media grid, as the Vault grid does. */
    mediaActions: com.nostrvault.ui.screens.MediaViewerViewModel = hiltViewModel(),
) {
    LaunchedEffect(isTab) { viewModel.setOpensAsTab(isTab) }
    LaunchedEffect(pubkey) {
        if (viewModel.pubkey.isEmpty() || viewModel.pubkey != pubkey) {
            viewModel.setPubkey(pubkey)
        }
    }

    val profile by viewModel.profile.collectAsState()
    // Held here, not in the header item, so scrolling it away does not restart the wait.
    val metadataWaitOver = rememberMetadataWaitOver(pubkey)
    val awaitingMetadata = ProfileMetadataWait.awaiting(profile, metadataWaitOver)
    val filteredNotes by viewModel.filteredNotes.collectAsState()
    val selectedSection by viewModel.selectedSection.collectAsState()
    val counts by viewModel.counts.collectAsState()
    val isFollowing by viewModel.isFollowing.collectAsState()
    val isOwnProfile by viewModel.isOwnProfile.collectAsState()
    // Your own profile is only yours to edit, sell from and delete on the
    // Profile tab; opened from a note it shows you as others see you (iOS
    // MyProfileView vs PersonProfileView).
    val isMyTab = isTab && isOwnProfile
    val visibleSections by viewModel.visibleSections.collectAsState()
    val isOwnerAccount = remember(pubkey) { viewModel.isOwnerAccount(pubkey) }
    val followsMe by viewModel.followsMe.collectAsState()
    val isBlocked by viewModel.isBlocked.collectAsState()
    val isLoading by viewModel.isLoading.collectAsState()
    val isLoadingOlder by viewModel.isLoadingOlder.collectAsState()
    val hasMoreNotes by viewModel.hasMoreNotes.collectAsState()
    val hasMoreTagged by viewModel.hasMoreTagged.collectAsState()
    val canPageOlderNotes by viewModel.canPageOlderNotes.collectAsState()
    val canPageOlderTagged by viewModel.canPageOlderTagged.collectAsState()
    val followersCount by viewModel.followersCount.collectAsState()
    val followingCount by viewModel.followingCount.collectAsState()
    val allProfiles by viewModel.profiles.collectAsState()
    val quotedNotes by viewModel.quotedNotesCache.collectAsState()
    val repostedIds by viewModel.repostedEventIds.collectAsState()
    // Read per row through derivedStateOf, so a relay's answer recomposes
    // only the rows whose numbers changed.
    val engagementState = viewModel.engagementLedgers.collectAsState()
    // Numbers on each post's buttons, fetched as the posts appear (iOS ProfileView).
    val noteIds = remember(filteredNotes) { filteredNotes.map { it.id } }
    LaunchedEffect(selectedSection, noteIds) {
        viewModel.loadEngagement()
    }
    val shopListings by viewModel.shopListings.collectAsState()
    val shopLoading by viewModel.shopLoading.collectAsState()
    val articles by viewModel.articles.collectAsState()
    val reels by viewModel.reels.collectAsState()
    val tracks by viewModel.tracks.collectAsState()
    var reelIndex by remember { mutableStateOf<Int?>(null) }
    // This screen already shows [pubkey]; tapping its own name must not open it again.
    val openOtherProfile: (String) -> Unit = remember(pubkey, onProfileClick) {
        { tapped -> if (tapped != pubkey) onProfileClick(tapped) }
    }
    val musicActions = remember(onComposeText, openOtherProfile) {
        com.nostrvault.ui.screens.music.MusicActions(
            onShare = onComposeText,
            onOpenProfile = openOtherProfile,
            npubToHex = viewModel::npubToHex,
        )
    }
    val currentTrack by com.nostrvault.service.music.MusicPlayer.current.collectAsState()
    val musicPlaying by com.nostrvault.service.music.MusicPlayer.isPlaying.collectAsState()
    var openListing by remember { mutableStateOf<com.nostrvault.data.model.MarketListing?>(null) }
    // The post bar's Web of Trust button: the author whose map is open.
    var trustWebAuthor by remember { mutableStateOf<String?>(null) }
    // Coming back from the Sell composer: show the listing just posted.
    var sellLaunched by rememberSaveable { mutableStateOf(false) }
    LaunchedEffect(Unit) { if (sellLaunched) { sellLaunched = false; viewModel.reloadShop() } }
    val colors = LocalNostrVaultColors.current
    val configuration = androidx.compose.ui.platform.LocalConfiguration.current
    // iOS lays the grids out from width only on iPad; phones keep their counts.
    val gridWidthDp = ProfileGrid.layoutWidth(configuration.screenWidthDp.toFloat(), configuration.smallestScreenWidthDp)
    val context = LocalContext.current
    val brainstormLink = remember(pubkey) { NostrWebLinks.forProfile(pubkey) }
    val lane = LocalNotificationManager.current
    val clipboard = LocalClipboardManager.current

    // Derived from the collected `profile` so they recompose when it loads.
    // From the argument, not the view model: the Profile tab's model has no
    // pubkey until the effect above sets it.
    val npub = remember(pubkey) { viewModel.npubOf(pubkey) }
    val lightningAddress = remember(profile) {
        profile?.let { p ->
            p.lud06?.takeIf { it.isNotBlank() }?.let { "lnurl:$it" }
                ?: p.lud16?.takeIf { it.isNotBlank() }
        }
    }
    val website = remember(profile) { profile?.website?.takeIf { it.isNotBlank() } }
    val canZap = viewModel.hasWallet && lightningAddress != null


    // The Media tab's urls, in grid order; a tap opens the app's full-screen
    // viewer on them (video, audio, drag to close; iOS MediaItemRenderer).
    val mediaItems = remember(filteredNotes, selectedSection) {
        if (selectedSection == ProfileSection.MEDIA) {
            filteredNotes.flatMap { note -> note.mediaURLs.map { it to note } }
        } else emptyList()
    }
    val listState = rememberLazyListState()
    // Re-tapping the Profile tab: back to the top, and fetched fresh, the
    // iPhone's way to refresh your own profile (iOS MyProfileView).
    if (isTab) {
        LaunchedEffect(Unit) {
            com.nostrvault.ui.navigation.TabReselect.of(com.nostrvault.ui.navigation.Screen.Profile)
                .collect {
                    viewModel.refresh()
                    listState.animateScrollToItem(0)
                }
        }
    }
    val density = androidx.compose.ui.platform.LocalDensity.current
    // Report Media / Block User from a Media grid tile's long-press menu.
    var gridReportTarget by remember { mutableStateOf<String?>(null) }
    var gridBlockTarget by remember { mutableStateOf<String?>(null) }
    // Delete from mirrors / everywhere on one of your own files: (blob hash, scope).
    var gridDelete by remember { mutableStateOf<Pair<String, com.nostrvault.ui.screens.DeleteScope>?>(null) }
    // Long-press on a profile zap button: choose the amount (iOS ZapSheetContext).
    var zapSheetOpen by remember { mutableStateOf(false) }
    // Edit Profile, over this page; swiping it away saves. Not saveable: the
    // form lives in the view model, so after process death the sheet would
    // come back empty.
    var editingProfile by remember { mutableStateOf(false) }
    val openEditor = { editViewModel.open(); editingProfile = true }
    val copyNpub = {
        npub?.let { clipboard.setText(AnnotatedString(it)) }
        Unit
    }

    GlassScaffold(
        // The banner runs up under the toolbar; the toolbar's fade comes in
        // as the page scrolls up behind it.
        toolbarScrimAlpha = {
            if (listState.firstVisibleItemIndex > 0) 1f
            else listState.firstVisibleItemScrollOffset / with(density) { 110.dp.toPx() }
        },
        toolbar = {
            Row(
                verticalAlignment = Alignment.CenterVertically,
                modifier = Modifier
                    .fillMaxWidth()
                    .statusBarsPadding()
                    .padding(horizontal = 12.dp, vertical = 8.dp),
            ) {
                if (!isTab) {
                    GlassPill {
                        IconButton(onClick = onBack, modifier = Modifier.size(40.dp)) {
                            Icon(NostrVaultIcons.Back, "Back", tint = PrimaryText, modifier = Modifier.size(25.dp))
                        }
                    }
                } else if (isOwnerAccount) {
                    // The wallet is the owner account's; another account's
                    // profile shows no ⚡ (iOS isOwnerProfile).
                    GlassPill {
                        IconButton(onClick = onOpenLightning, modifier = Modifier.size(40.dp)) {
                            Icon(NostrVaultIcons.Zap, "Lightning", tint = colors.primary, modifier = Modifier.size(25.dp))
                        }
                    }
                }

                Spacer(Modifier.weight(1f))

                // Messages moved to the Vault tab's right pill. Your own
                // profile opened from a note has nothing here (iOS isYou).
                if (isMyTab) {
                    GlassPill {
                        IconButton(onClick = onNavigateToSettings, modifier = Modifier.size(40.dp)) {
                            Icon(NostrVaultIcons.Settings, "Settings", tint = PrimaryText, modifier = Modifier.size(25.dp))
                        }
                    }
                } else if (!isOwnProfile) {
                    GlassPill {
                        IconButton(onClick = { onNavigateToDMThread(pubkey) }, modifier = Modifier.size(40.dp)) {
                            Icon(NostrVaultIcons.Chat, "Message", tint = colors.primary, modifier = Modifier.size(25.dp))
                        }
                    }
                }
            }
        },
        // iOS has the Post capsule on the Profile tab only (MyProfileView.postButton).
        floatingActionButton = { if (isTab) ProfilePostCapsule(onPost = onCompose) },
    ) { padding ->
        // Items before the section tabs: header, bio (when there is one),
        // links, follow counts and actions.
        val tabsIndex = if (profile?.about?.isNotBlank() == true) 5 else 4
        // A section is at least as tall as the screen, so picking one with a
        // single item keeps the tabs where they were instead of the page
        // snapping back down (iOS #283). This blank space after the section
        // makes up the difference.
        var fillerPx by remember { mutableIntStateOf(0) }
        LaunchedEffect(listState, tabsIndex) {
            snapshotFlow { ProfileTabFiller.needed(listState.layoutInfo, tabsIndex) }
                .collect { needed -> if (needed != null) fillerPx = needed }
        }
        val selectSection: (ProfileSection) -> Unit = { section ->
            // Until the new section is measured, assume it is short; the
            // measurement then trims this to what it needs.
            fillerPx = ProfileTabFiller.visibleHeight(listState.layoutInfo)
            viewModel.setSection(section)
        }
        val list: @Composable () -> Unit = {
        LazyColumn(
            state = listState,
            contentPadding = PaddingValues(
                top = padding.calculateTopPadding(),
                bottom = padding.calculateBottomPadding() + 88.dp,
            ),
            modifier = Modifier.fillMaxSize(),
        ) {
            item {
                ProfileBanner(
                    bannerUrl = profile?.bannerURL?.takeIf { it.isNotBlank() },
                    avatarUrl = profile?.pictureURL?.takeIf { it.isNotBlank() },
                    pubkey = pubkey,
                    topInset = padding.calculateTopPadding(),
                    accent = colors.primary,
                    onTap = { com.nostrvault.ui.components.FullScreenMediaRouter.open(listOf(it), 0, copyLink = true) },
                )
                ProfileHeader(
                    profile = profile,
                    pubkey = pubkey,
                    isOwnProfile = isOwnProfile,
                    isFollowing = isFollowing,
                    followsMe = followsMe,
                    awaiting = awaitingMetadata,
                )
            }


            profile?.about?.takeIf { it.isNotBlank() }?.let { bio ->
                item {
                    NostrContentText(
                        content = bio,
                        profiles = allProfiles,
                        onProfileClick = openOtherProfile,
                        textColor = PrimaryText.copy(alpha = 0.85f),
                        fontSize = 13.sp,
                        lineHeight = 18.sp,
                        modifier = Modifier
                            .fillMaxWidth()
                            .padding(start = 16.dp, end = 16.dp, top = 12.dp),
                    )
                }
            }

            item {
                ProfileLinksRow(
                    lightning = lightningAddress,
                    website = website,
                    npub = npub,
                    onCopyLightning = {
                        lightningAddress?.let { clipboard.setText(AnnotatedString(it)) }
                    },
                    onCopyNpub = copyNpub,
                    awaiting = awaitingMetadata,
                )
            }

            item {
                ProfileFollowCounts(
                    following = followingCount,
                    followers = followersCount,
                    onOpenFollowList = { tab -> onOpenFollowList(tab, followersCount) },
                )
            }

            item {
                ProfileActionRow(
                    isOwnProfile = isOwnProfile,
                    isFollowing = isFollowing,
                    isBlocked = isBlocked,
                    canZap = canZap,
                    zapSats = viewModel.defaultZapSats,
                    onEditProfile = openEditor,
                    onFollow = viewModel::toggleFollow,
                    onMessage = { onNavigateToDMThread(pubkey) },
                    onBlock = viewModel::toggleBlock,
                    onZap = { viewModel.zap() },
                    onZapLongPress = { zapSheetOpen = true },
                    onTrustWeb = { trustWebAuthor = pubkey },
                    // iOS copies from ⋯ without a notice; Android 13+ shows its
                    // own clipboard confirmation, older versions show nothing.
                    onCopyNpub = {
                        copyNpub()
                        if (android.os.Build.VERSION.SDK_INT < 33) lane.showFeedback("Public key copied", NostrVaultIcons.Copy)
                    },
                    webLink = brainstormLink,
                    onOpenWebLink = { brainstormLink?.let { NostrWebLinks.open(context, it.url) } },
                    onOpenMyProfile = if (isTab) null else onOpenMyProfile,
                    zapBursts = viewModel.zapBursts,
                )
                // One rule above the tabs instead of one between every block.
                HorizontalDivider(
                    color = SeparatorColor.copy(alpha = 0.6f),
                    thickness = 0.5.dp,
                    modifier = Modifier.padding(vertical = 16.dp),
                )
            }

            item(key = "section-tabs") {
                ProfileSectionTabs(
                    selected = selectedSection,
                    counts = counts,
                    hasMore = { section ->
                        when (section) {
                            ProfileSection.TAGGED -> hasMoreTagged
                            else -> section.isNoteList && hasMoreNotes
                        }
                    },
                    extraCounts = mapOf(
                        ProfileSection.SHOP to shopListings.size,
                        ProfileSection.ARTICLES to articles.size,
                        ProfileSection.DIVINES to reels.size,
                        ProfileSection.MUSIC to tracks.size,
                    ),
                    // Shop only shows when this person sells something, or on
                    // the Profile tab where it holds the Sell button; the
                    // others only when this person has some, all at once
                    // when their loads are done (ProfileLateTabs).
                    shown = { it in visibleSections },
                    onSelect = selectSection,
                )
            }

            // ── Section content ──────────────────────────────────────
            if (selectedSection == ProfileSection.ARTICLES) {
                // Cards carry 6 above and below; 10 more puts the first 16 under the tabs, as iOS.
                item(key = "articles-top") { Spacer(Modifier.height(10.dp)) }
                items(articles, key = { "article-" + it.id }) { article ->
                    ProfileArticleRow(article, onClick = { onArticleClick(viewModel.prepareOpen(article)) })
                }
                item(key = "articles-bottom") { Spacer(Modifier.height(10.dp)) }
            } else if (selectedSection == ProfileSection.DIVINES) {
                // 9:16 posters, as many 110+ wide as fit; a tap plays them in a viewer.
                val cols = ProfileGrid.divineColumns(gridWidthDp)
                items(reels.withIndex().chunked(cols), key = { row -> "divine-" + row.first().value.id }) { row ->
                    Row(
                        horizontalArrangement = Arrangement.spacedBy(4.dp),
                        modifier = Modifier
                            .fillMaxWidth()
                            .padding(horizontal = 16.dp, vertical = 2.dp),
                    ) {
                        row.forEach { (index, reel) ->
                            DiVineTile(reel, onClick = { reelIndex = index }, modifier = Modifier.weight(1f))
                        }
                        repeat(cols - row.size) { Spacer(Modifier.weight(1f)) }
                    }
                }
            } else if (selectedSection == ProfileSection.MUSIC) {
                itemsIndexed(tracks, key = { _, t -> "track-" + t.id }) { index, track ->
                    Box(Modifier.padding(horizontal = 16.dp)) {
                        com.nostrvault.ui.screens.music.MusicTrackRow(
                            track = track,
                            isCurrent = currentTrack?.id == track.id,
                            isPlaying = musicPlaying,
                            actions = musicActions,
                            onTap = {
                                if (currentTrack?.id == track.id) com.nostrvault.service.music.MusicPlayer.togglePlayPause()
                                else com.nostrvault.service.music.MusicPlayer.play(tracks, index)
                            },
                        )
                    }
                }
            } else if (selectedSection == ProfileSection.SHOP) {
                if (isMyTab) {
                    item {
                        Button(
                            onClick = { sellLaunched = true; onSell() },
                            colors = ButtonDefaults.buttonColors(containerColor = colors.primary),
                            shape = RoundedCornerShape(12.dp),
                            modifier = Modifier
                                .fillMaxWidth()
                                .padding(horizontal = 16.dp, vertical = 12.dp),
                        ) {
                            Icon(NostrVaultIcons.Marketplace, contentDescription = null, tint = Color.White, modifier = Modifier.size(16.dp))
                            Spacer(Modifier.width(6.dp))
                            Text("Sell something", color = Color.White, fontWeight = FontWeight.Bold)
                        }
                    }
                }
                if (shopListings.isEmpty()) {
                    item {
                        Column(
                            horizontalAlignment = Alignment.CenterHorizontally,
                            verticalArrangement = Arrangement.spacedBy(10.dp),
                            modifier = Modifier.fillMaxWidth().padding(vertical = 36.dp),
                        ) {
                            Icon(NostrVaultIcons.Marketplace, contentDescription = null, tint = SecondaryText.copy(alpha = 0.5f), modifier = Modifier.size(24.dp))
                            Text(
                                text = when {
                                    shopLoading -> "Loading…"
                                    isMyTab -> "You haven't listed anything yet"
                                    else -> "Nothing for sale"
                                },
                                color = SecondaryText,
                                fontSize = 12.sp,
                            )
                        }
                    }
                } else {
                    val cols = ProfileGrid.shopColumns(gridWidthDp)
                    items(shopListings.chunked(cols), key = { row -> "shop-" + row.first().id }) { row ->
                        Row(
                            horizontalArrangement = Arrangement.spacedBy(12.dp),
                            modifier = Modifier
                                .fillMaxWidth()
                                .padding(horizontal = 16.dp, vertical = 6.dp),
                        ) {
                            row.forEach { listing ->
                                Box(Modifier.weight(1f)) {
                                    com.nostrvault.ui.screens.feed.ListingCard(listing, profile, onClick = { openListing = listing })
                                }
                            }
                            repeat(cols - row.size) { Spacer(Modifier.weight(1f)) }
                        }
                    }
                }
            } else if (isLoading && filteredNotes.isEmpty()) {
                item { CenteredSpinner(colors.primary) }
            } else if (filteredNotes.isEmpty()) {
                val section = selectedSection
                item(key = "empty-${section.name}") {
                    val canPageOlder = when {
                        section == ProfileSection.TAGGED -> canPageOlderTagged
                        section.isNoteList -> canPageOlderNotes
                        else -> false
                    }
                    ProfileEmptySection(
                        section = section,
                        opening = isLoading,
                        pagingNow = isLoadingOlder,
                        canPageOlder = canPageOlder,
                        onAutoPage = { viewModel.autoPageEmptyTab(section) },
                        onLookFurther = { viewModel.loadOlder(section) },
                    )
                }
            } else if (selectedSection == ProfileSection.MEDIA) {
                // Three across on a phone, more on a tablet (iOS ideal 180),
                // as chunked rows (nested-scroll-safe).
                val cols = ProfileGrid.mediaColumns(gridWidthDp)
                items(mediaItems.chunked(cols)) { row ->
                    Row(
                        horizontalArrangement = Arrangement.spacedBy(ProfileGrid.MEDIA_SPACING_DP.dp),
                        modifier = Modifier
                            .fillMaxWidth()
                            .padding(horizontal = 8.dp, vertical = (ProfileGrid.MEDIA_SPACING_DP / 2).dp),
                    ) {
                        row.forEach { (url, note) ->
                            val idx = mediaItems.indexOfFirst { it.first == url }
                            Box(Modifier.weight(1f).aspectRatio(1f)) {
                                ProfileMediaTile(
                                    url = url,
                                    author = note.pubkey,
                                    viewModel = viewModel,
                                    onOpen = {
                                        com.nostrvault.ui.components.FullScreenMediaRouter.open(
                                            mediaItems.map { it.first }, idx, copyLink = true,
                                        )
                                    },
                                    onReport = { gridReportTarget = it },
                                    onBlock = { gridBlockTarget = it },
                                    onDelete = { hash, scope -> gridDelete = hash to scope },
                                )
                            }
                        }
                        repeat(cols - row.size) { Spacer(Modifier.weight(1f)) }
                    }
                }
            } else {
                items(items = filteredNotes, key = { it.id }) { note ->
                    val engagement by remember(note.effectiveEventId, selectedSection) {
                        derivedStateOf {
                            if (selectedSection == ProfileSection.TAGGED) null
                            else viewModel.engagementFor(engagementState.value, note.effectiveEventId)
                        }
                    }
                    NoteCard(
                        note = note,
                        avatarMenu = viewModel.avatarMenu,
                        // A repost on this profile is someone else's note:
                        // credit its author, not the profile's owner.
                        profile = if (selectedSection == ProfileSection.TAGGED || note.kind == 6)
                            allProfiles[note.pubkey] else profile,
                        profiles = allProfiles,
                        quotedNotes = quotedNotes,
                        isLiked = viewModel.isLiked(note.effectiveEventId),
                        isReposted = note.effectiveEventId in repostedIds,
                        repostedByProfile = note.repostedBy?.let { allProfiles[it] },
                        onNoteClick = onNoteClick,
                        onArticleClick = onArticleClick,
                        onProfileClick = openOtherProfile,
                        onLike = viewModel::likeNote,
                        onRepost = viewModel::repostNote,
                        onReply = onReply,
                        onQuote = onQuote,
                        onZap = { viewModel.zapNote(note.effectiveEventId, note.effectiveAuthor) },
                        onTrustWeb = if (viewModel.isOwnNote(note.effectiveAuthor)) null else ({ author: String -> trustWebAuthor = author }),
                        engagement = engagement,
                    )
                    HorizontalDivider(color = SeparatorColor, thickness = 0.5.dp)
                }
            }

            // ── Infinite-scroll sentinel ─────────────────────────────
            val hasMore = if (selectedSection == ProfileSection.TAGGED) hasMoreTagged else hasMoreNotes
            if (selectedSection.isNoteList && !isLoading && filteredNotes.isNotEmpty() && hasMore) {
                item(key = "load-more-${selectedSection.name}-${filteredNotes.size}") {
                    LaunchedEffect(Unit) { viewModel.loadOlder() }
                    if (isLoadingOlder) {
                        CenteredSpinner(colors.primary)
                    } else {
                        Spacer(Modifier.height(24.dp))
                    }
                }
            }

            // Keeps a short section from pulling the tabs down (see fillerPx).
            item(key = ProfileTabFiller.KEY) {
                val density = androidx.compose.ui.platform.LocalDensity.current
                Spacer(Modifier.height(with(density) { fillerPx.toDp() }))
            }
        }
        }
        // Your own profile has nothing that needs pulling fresh, so the pull
        // opens the editor instead (iOS #456). Editing lives on the tab.
        if (isMyTab) {
            PullToEditBox(labelTop = padding.calculateTopPadding(), onTrigger = openEditor) { list() }
        } else {
            list()
        }
    }

    if (editingProfile) {
        ProfileEditSheet(viewModel = editViewModel, onClose = { editingProfile = false })
    }

    openListing?.let { listing ->
        com.nostrvault.ui.screens.feed.MarketListingSheet(
            listing = listing,
            seller = profile,
            onOpenSeller = null,
            // Not to yourself: your own Shop tab lists what you sell.
            onMessageSeller = if (isOwnProfile) null else { l -> openListing = null; onMessageUser(l.pubkey, l.messageToSeller) },
            onEventInfo = null,
            onDismiss = { openListing = null },
        )
    }

    trustWebAuthor?.let { author ->
        TrustWebDialog(
            author = author,
            initialPath = null,
            onProfileClick = openOtherProfile,
            onDismiss = { trustWebAuthor = null },
        )
    }

    // Reporting also blocks the author, as on iOS and everywhere else in the app.
    gridReportTarget?.let { pubkey ->
        com.nostrvault.ui.components.UGCReportDialog(
            onReport = { reason, description ->
                gridReportTarget = null
                viewModel.reportAuthor(pubkey, reason, description)
                viewModel.blockAuthor(pubkey)
            },
            onDismiss = { gridReportTarget = null },
        )
    }
    gridBlockTarget?.let { pubkey ->
        AlertDialog(
            onDismissRequest = { gridBlockTarget = null },
            title = { Text("Block User") },
            text = { Text("Block this user? Their posts will be hidden from your feed.") },
            confirmButton = {
                TextButton(onClick = {
                    gridBlockTarget = null
                    viewModel.blockAuthor(pubkey)
                }) { Text("Block", color = ErrorRed) }
            },
            dismissButton = {
                TextButton(onClick = { gridBlockTarget = null }) { Text("Cancel") }
            },
        )
    }

    // Same confirmation as the Vault grid. The tile stays, as on iOS: it
    // belongs to a post, and the post is still up unless that was chosen too.
    gridDelete?.let { (hash, scope) ->
        val postCount = remember(hash, scope) {
            if (scope == com.nostrvault.ui.screens.DeleteScope.EVERYWHERE) mediaActions.postsUsing(hash) else 0
        }
        fun confirm(deletePosts: Boolean) {
            gridDelete = null
            // The delete calls only read the hash.
            val item = com.nostrvault.ui.screens.BlossomMediaItem(
                sha256 = hash, displayUrl = "", localFile = null, mimeType = null,
                size = null, uploaded = null, lastModified = null, isLocal = false,
            )
            when (scope) {
                com.nostrvault.ui.screens.DeleteScope.MIRRORS -> mediaActions.deleteFromMirrors(item)
                com.nostrvault.ui.screens.DeleteScope.EVERYWHERE ->
                    mediaActions.deleteEverywhere(item, deletePosts = deletePosts) {}
            }
        }
        com.nostrvault.ui.screens.DeleteBlobConfirmDialog(
            scope = scope,
            postCount = postCount,
            onConfirm = { confirm(deletePosts = false) },
            onConfirmWithPosts = { confirm(deletePosts = true) },
            onDismiss = { gridDelete = null },
        )
    }

    if (zapSheetOpen) {
        com.nostrvault.ui.components.CustomZapSheet(
            sheetState = rememberModalBottomSheetState(skipPartiallyExpanded = true),
            defaultAmount = viewModel.defaultZapSats,
            onDismiss = { zapSheetOpen = false },
            onZap = { amount ->
                zapSheetOpen = false
                viewModel.zap(amount)
            },
        )
    }

    reelIndex?.let { start ->
        if (reels.isNotEmpty()) {
            DiVineViewer(reels, start.coerceIn(0, reels.lastIndex), onDismiss = { reelIndex = null })
        }
    }
}

@Composable
private fun CenteredSpinner(tint: Color) {
    Box(
        contentAlignment = Alignment.Center,
        modifier = Modifier
            .fillMaxWidth()
            .padding(24.dp),
    ) {
        CircularProgressIndicator(color = tint, modifier = Modifier.size(24.dp))
    }
}
