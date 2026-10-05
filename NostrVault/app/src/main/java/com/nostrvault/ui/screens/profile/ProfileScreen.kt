package com.nostrvault.ui.screens.profile

import android.widget.Toast
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.lazy.itemsIndexed
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.foundation.pager.HorizontalPager
import androidx.compose.foundation.pager.rememberPagerState
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.*
import androidx.compose.material3.pulltorefresh.PullToRefreshBox
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Speed
import androidx.compose.runtime.*
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.layout.ContentScale
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
import com.nostrvault.ui.theme.*

/**
 * User profile screen — ports iOS ProfileView: header + status badge, action
 * row, stats, identity rows, 4 section tabs (Notes/Media/Replies/Tagged) with
 * counts, infinite scroll, a media grid, and a full-screen media viewer.
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun ProfileScreen(
    pubkey: String,
    onNoteClick: (String) -> Unit,
    /** Where a quoted long-form post opens; the note screen would show its Markdown source. */
    onArticleClick: (String) -> Unit,
    onProfileClick: (String) -> Unit,
    onEditProfile: () -> Unit,
    onCompose: () -> Unit = {},
    onReply: (String) -> Unit = {},
    onQuote: (String) -> Unit = {},
    onNavigateToDMs: () -> Unit = {},
    onNavigateToDMThread: (String) -> Unit = {},
    /** Opens a DM with a pubkey, its box prefilled (Message seller). */
    onMessageUser: (pubkey: String, draft: String) -> Unit = { pk, _ -> onNavigateToDMThread(pk) },
    onNavigateToSettings: () -> Unit = {},
    /** Opens the Sell composer (own profile, Shop tab). */
    onSell: () -> Unit = {},
    /** Opens the composer with text in it (sharing a song from the Music tab). */
    onComposeText: (String) -> Unit = {},
    onBack: () -> Unit,
    viewModel: ProfileViewModel = hiltViewModel(),
) {
    LaunchedEffect(pubkey) {
        if (viewModel.pubkey.isEmpty() || viewModel.pubkey != pubkey) {
            viewModel.setPubkey(pubkey)
        }
    }

    val profile by viewModel.profile.collectAsState()
    val filteredNotes by viewModel.filteredNotes.collectAsState()
    val selectedSection by viewModel.selectedSection.collectAsState()
    val counts by viewModel.counts.collectAsState()
    val isFollowing by viewModel.isFollowing.collectAsState()
    val isOwnProfile by viewModel.isOwnProfile.collectAsState()
    val followsMe by viewModel.followsMe.collectAsState()
    val isBlocked by viewModel.isBlocked.collectAsState()
    val isThrottled by viewModel.isThrottled.collectAsState()
    val isLoading by viewModel.isLoading.collectAsState()
    val isRefreshing by viewModel.isRefreshing.collectAsState()
    val isLoadingOlder by viewModel.isLoadingOlder.collectAsState()
    val hasMoreNotes by viewModel.hasMoreNotes.collectAsState()
    val hasMoreTagged by viewModel.hasMoreTagged.collectAsState()
    val followersCount by viewModel.followersCount.collectAsState()
    val followingCount by viewModel.followingCount.collectAsState()
    val allProfiles by viewModel.profiles.collectAsState()
    val quotedNotes by viewModel.quotedNotesCache.collectAsState()
    val repostedIds by viewModel.repostedEventIds.collectAsState()
    val toast by viewModel.toast.collectAsState()
    val shopListings by viewModel.shopListings.collectAsState()
    val shopLoading by viewModel.shopLoading.collectAsState()
    val articles by viewModel.articles.collectAsState()
    val reels by viewModel.reels.collectAsState()
    val tracks by viewModel.tracks.collectAsState()
    var reelIndex by remember { mutableStateOf<Int?>(null) }
    val musicActions = remember(onComposeText, onProfileClick) {
        com.nostrvault.ui.screens.music.MusicActions(
            onShare = onComposeText,
            onOpenProfile = onProfileClick,
            npubToHex = viewModel::npubToHex,
        )
    }
    val currentTrack by com.nostrvault.service.music.MusicPlayer.current.collectAsState()
    val musicPlaying by com.nostrvault.service.music.MusicPlayer.isPlaying.collectAsState()
    var openListing by remember { mutableStateOf<com.nostrvault.data.model.MarketListing?>(null) }
    // Coming back from the Sell composer: show the listing just posted.
    var sellLaunched by rememberSaveable { mutableStateOf(false) }
    LaunchedEffect(Unit) { if (sellLaunched) { sellLaunched = false; viewModel.reloadShop() } }
    val colors = LocalNostrVaultColors.current
    val context = LocalContext.current
    val clipboard = LocalClipboardManager.current

    // Derived from the collected `profile` so they recompose when it loads.
    val npub = remember(pubkey) { viewModel.npub }
    val lightningAddress = remember(profile) {
        profile?.let { p ->
            p.lud06?.takeIf { it.isNotBlank() }?.let { "lnurl:$it" }
                ?: p.lud16?.takeIf { it.isNotBlank() }
        }
    }
    val website = remember(profile) { profile?.website?.takeIf { it.isNotBlank() } }
    val canZap = viewModel.hasWallet && lightningAddress != null

    // Transient action feedback (zap / block).
    LaunchedEffect(toast) {
        toast?.let {
            Toast.makeText(context, it, Toast.LENGTH_SHORT).show()
            viewModel.clearToast()
        }
    }

    // Full-screen media viewer state: media urls for the current (Media) tab.
    val mediaItems = remember(filteredNotes, selectedSection) {
        if (selectedSection == ProfileSection.MEDIA) {
            filteredNotes.flatMap { note -> note.mediaURLs.map { it to note } }
        } else emptyList()
    }
    var viewerIndex by remember { mutableStateOf<Int?>(null) }

    GlassScaffold(
        toolbar = {
            Row(
                verticalAlignment = Alignment.CenterVertically,
                modifier = Modifier
                    .fillMaxWidth()
                    .statusBarsPadding()
                    .padding(horizontal = 12.dp, vertical = 8.dp),
            ) {
                GlassPill {
                    if (isOwnProfile) {
                        IconButton(onClick = { /* lightning wallet */ }, modifier = Modifier.size(40.dp)) {
                            Icon(NostrVaultIcons.Zap, "Lightning", tint = colors.primary, modifier = Modifier.size(25.dp))
                        }
                    } else {
                        IconButton(onClick = onBack, modifier = Modifier.size(40.dp)) {
                            Icon(NostrVaultIcons.Back, "Back", tint = PrimaryText, modifier = Modifier.size(25.dp))
                        }
                    }
                }

                Spacer(Modifier.weight(1f))

                GlassPill {
                    if (isOwnProfile) {
                        IconButton(onClick = onNavigateToDMs, modifier = Modifier.size(40.dp)) {
                            Icon(NostrVaultIcons.DMs, "Messages", tint = PrimaryText, modifier = Modifier.size(25.dp))
                        }
                        IconButton(onClick = onNavigateToSettings, modifier = Modifier.size(40.dp)) {
                            Icon(NostrVaultIcons.Settings, "Settings", tint = PrimaryText, modifier = Modifier.size(25.dp))
                        }
                    } else {
                        IconButton(onClick = { onNavigateToDMThread(pubkey) }, modifier = Modifier.size(40.dp)) {
                            Icon(NostrVaultIcons.Chat, "Message", tint = SecondaryText, modifier = Modifier.size(25.dp))
                        }
                    }
                }
            }
        },
    ) { padding ->
        val listState = rememberLazyListState()
        // Items before the section tabs: header, actions, bio (when there is
        // one), stats and identity rows.
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
                ProfileHeader(
                    profile = profile,
                    pubkey = pubkey,
                    npub = npub,
                    isOwnProfile = isOwnProfile,
                    isFollowing = isFollowing,
                    followsMe = followsMe,
                    onCopyNpub = {
                        npub?.let {
                            clipboard.setText(AnnotatedString(it))
                            Toast.makeText(context, "Public key copied", Toast.LENGTH_SHORT).show()
                        }
                    },
                )
            }

            item {
                ProfileActionRow(
                    isOwnProfile = isOwnProfile,
                    isFollowing = isFollowing,
                    isBlocked = isBlocked,
                    isThrottled = isThrottled,
                    canZap = canZap,
                    zapSats = viewModel.defaultZapSats,
                    onCompose = onCompose,
                    onEditProfile = onEditProfile,
                    onFollow = viewModel::toggleFollow,
                    onMessage = { onNavigateToDMThread(pubkey) },
                    onBlock = viewModel::toggleBlock,
                    onThrottle = viewModel::toggleThrottle,
                    onZap = viewModel::zap,
                )
            }

            profile?.about?.takeIf { it.isNotBlank() }?.let { bio ->
                item {
                    NostrContentText(
                        content = bio,
                        profiles = allProfiles,
                        onProfileClick = onProfileClick,
                        textColor = SecondaryText,
                        fontSize = 14.sp,
                        lineHeight = 20.sp,
                        modifier = Modifier
                            .fillMaxWidth()
                            .padding(horizontal = 16.dp, vertical = 4.dp),
                    )
                }
            }

            item {
                ProfileStatsRow(
                    notes = counts.notes,
                    media = counts.media,
                    following = followingCount,
                    followers = followersCount,
                    isOwnProfile = isOwnProfile,
                )
            }

            item {
                ProfileIdentityRows(
                    lightning = lightningAddress,
                    website = website,
                    onCopyLightning = {
                        lightningAddress?.let {
                            clipboard.setText(AnnotatedString(it))
                            Toast.makeText(context, "Lightning address copied", Toast.LENGTH_SHORT).show()
                        }
                    },
                )
            }

            item(key = "section-tabs") {
                ProfileSectionTabs(
                    selected = selectedSection,
                    counts = counts,
                    extraCounts = mapOf(
                        ProfileSection.SHOP to shopListings.size,
                        ProfileSection.ARTICLES to articles.size,
                        ProfileSection.DIVINES to reels.size,
                        ProfileSection.MUSIC to tracks.size,
                    ),
                    // Shop only shows when this person sells something, or on
                    // your own profile where it holds the Sell button; the
                    // others only when this person has some.
                    shown = { section ->
                        when (section) {
                            ProfileSection.SHOP -> isOwnProfile || shopListings.isNotEmpty()
                            ProfileSection.ARTICLES -> articles.isNotEmpty()
                            ProfileSection.DIVINES -> reels.isNotEmpty()
                            ProfileSection.MUSIC -> tracks.isNotEmpty()
                            else -> true
                        }
                    },
                    onSelect = selectSection,
                )
            }

            // ── Section content ──────────────────────────────────────
            if (selectedSection == ProfileSection.ARTICLES) {
                items(articles, key = { "article-" + it.id }) { article ->
                    ProfileArticleRow(article, onClick = { onArticleClick(viewModel.prepareOpen(article)) })
                    HorizontalDivider(color = colors.primary.copy(alpha = 0.10f))
                }
            } else if (selectedSection == ProfileSection.DIVINES) {
                // 9:16 posters, three to a row; a tap plays them in a viewer.
                items(reels.withIndex().chunked(3), key = { row -> "divine-" + row.first().value.id }) { row ->
                    Row(
                        horizontalArrangement = Arrangement.spacedBy(4.dp),
                        modifier = Modifier
                            .fillMaxWidth()
                            .padding(horizontal = 8.dp, vertical = 2.dp),
                    ) {
                        row.forEach { (index, reel) ->
                            DiVineTile(reel, onClick = { reelIndex = index }, modifier = Modifier.weight(1f))
                        }
                        repeat(3 - row.size) { Spacer(Modifier.weight(1f)) }
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
                if (isOwnProfile) {
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
                        Box(contentAlignment = Alignment.Center, modifier = Modifier.fillMaxWidth().padding(40.dp)) {
                            Text(
                                text = when {
                                    shopLoading -> "Loading…"
                                    isOwnProfile -> "You haven't listed anything yet"
                                    else -> "Nothing for sale"
                                },
                                color = SecondaryText,
                                fontSize = 15.sp,
                            )
                        }
                    }
                } else {
                    items(shopListings.chunked(2), key = { row -> "shop-" + row.first().id }) { row ->
                        Row(
                            horizontalArrangement = Arrangement.spacedBy(10.dp),
                            modifier = Modifier
                                .fillMaxWidth()
                                .padding(horizontal = 12.dp, vertical = 6.dp),
                        ) {
                            row.forEach { listing ->
                                Box(Modifier.weight(1f)) {
                                    com.nostrvault.ui.screens.feed.ListingCard(listing, profile, onClick = { openListing = listing })
                                }
                            }
                            if (row.size == 1) Spacer(Modifier.weight(1f))
                        }
                    }
                }
            } else if (isLoading && filteredNotes.isEmpty()) {
                item { CenteredSpinner(colors.primary) }
            } else if (filteredNotes.isEmpty()) {
                item {
                    Box(
                        contentAlignment = Alignment.Center,
                        modifier = Modifier
                            .fillMaxWidth()
                            .padding(40.dp),
                    ) {
                        Text(
                            text = "No ${selectedSection.displayName.lowercase()} yet",
                            color = SecondaryText,
                            fontSize = 15.sp,
                        )
                    }
                }
            } else if (selectedSection == ProfileSection.MEDIA) {
                // 3-column media grid as chunked rows (nested-scroll-safe).
                items(mediaItems.chunked(3)) { row ->
                    Row(
                        horizontalArrangement = Arrangement.spacedBy(4.dp),
                        modifier = Modifier
                            .fillMaxWidth()
                            .padding(horizontal = 8.dp, vertical = 2.dp),
                    ) {
                        row.forEach { (url, _) ->
                            val idx = mediaItems.indexOfFirst { it.first == url }
                            AsyncImage(
                                model = url,
                                contentDescription = null,
                                contentScale = ContentScale.Crop,
                                modifier = Modifier
                                    .weight(1f)
                                    .aspectRatio(1f)
                                    .clip(RoundedCornerShape(6.dp))
                                    .background(SecondaryGroupedBg)
                                    .clickable { viewerIndex = idx },
                            )
                        }
                        repeat(3 - row.size) { Spacer(Modifier.weight(1f)) }
                    }
                }
            } else {
                items(items = filteredNotes, key = { it.id }) { note ->
                    NoteCard(
                        note = note,
                        profile = if (selectedSection == ProfileSection.TAGGED)
                            allProfiles[note.pubkey] else profile,
                        stats = viewModel.statsFor(note.id),
                        profiles = allProfiles,
                        quotedNotes = quotedNotes,
                        isLiked = viewModel.isLiked(note.id),
                        isReposted = note.effectiveEventId in repostedIds,
                        repostedByProfile = note.repostedBy?.let { allProfiles[it] },
                        onNoteClick = onNoteClick,
                        onArticleClick = onArticleClick,
                        onProfileClick = onProfileClick,
                        onLike = viewModel::likeNote,
                        onRepost = viewModel::repostNote,
                        onReply = onReply,
                        onQuote = onQuote,
                        onZap = { viewModel.zapNote(note.effectiveEventId, note.pubkey) },
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
        // Pull to refresh on your own profile, as on iOS.
        if (isOwnProfile) {
            PullToRefreshBox(
                isRefreshing = isRefreshing,
                onRefresh = viewModel::refresh,
                modifier = Modifier.fillMaxSize(),
            ) { list() }
        } else {
            list()
        }
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

    reelIndex?.let { start ->
        if (reels.isNotEmpty()) {
            DiVineViewer(reels, start.coerceIn(0, reels.lastIndex), onDismiss = { reelIndex = null })
        }
    }

    // Full-screen media viewer overlay.
    viewerIndex?.let { startIndex ->
        if (mediaItems.isNotEmpty()) {
            MediaViewerOverlay(
                urls = mediaItems.map { it.first },
                startIndex = startIndex.coerceIn(0, mediaItems.size - 1),
                onDismiss = { viewerIndex = null },
            )
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

@Composable
private fun ProfileHeader(
    profile: com.nostrvault.data.model.FeedProfile?,
    pubkey: String,
    npub: String?,
    isOwnProfile: Boolean,
    isFollowing: Boolean,
    followsMe: Boolean,
    onCopyNpub: () -> Unit,
) {
    val colors = LocalNostrVaultColors.current

    Row(
        modifier = Modifier
            .fillMaxWidth()
            .padding(horizontal = 16.dp, vertical = 16.dp),
        horizontalArrangement = Arrangement.spacedBy(14.dp),
    ) {
        AvatarImage(
            url = profile?.pictureURL,
            pubkey = profile?.pubkey ?: pubkey,
            size = 64.dp,
            displayName = profile?.bestName,
        )

        Column(modifier = Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(4.dp)) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Text(
                    text = profile?.bestName ?: "${pubkey.take(8)}…",
                    color = PrimaryText,
                    fontSize = 20.sp,
                    fontWeight = FontWeight.Bold,
                )
                if (!profile?.nip05.isNullOrBlank()) {
                    Spacer(Modifier.width(6.dp))
                    Icon(
                        NostrVaultIcons.Verified,
                        contentDescription = null,
                        tint = colors.primary,
                        modifier = Modifier.size(14.dp),
                    )
                }
                Spacer(Modifier.weight(1f))
                StatusBadge(isOwnProfile, isFollowing, followsMe)
            }

            profile?.nip05?.takeIf { it.isNotBlank() }?.let {
                Text(text = it, color = SecondaryText, fontSize = 12.sp)
            }

            Row(
                verticalAlignment = Alignment.CenterVertically,
                modifier = Modifier.clickable(onClick = onCopyNpub),
            ) {
                Text(
                    text = npub?.let { "${it.take(12)}…${it.takeLast(8)}" } ?: "npub…",
                    color = SecondaryText,
                    fontSize = 11.sp,
                )
                Spacer(Modifier.width(5.dp))
                Icon(NostrVaultIcons.Copy, "Copy", tint = SecondaryText, modifier = Modifier.size(11.dp))
            }
        }
    }
}

@Composable
private fun StatusBadge(isOwnProfile: Boolean, isFollowing: Boolean, followsMe: Boolean) {
    val colors = LocalNostrVaultColors.current
    val mutualColor = Color(0xFF33E6B3)
    when {
        isOwnProfile -> Badge("YOU", colors.primary)
        isFollowing && followsMe -> Badge("∞ MUTUAL", mutualColor)
        isFollowing -> Badge("FOLLOWING", Color(0xFF4CAF50))
        followsMe -> Badge("FOLLOWS YOU", SecondaryText)
        else -> {}
    }
}

@Composable
private fun Badge(text: String, color: Color) {
    Text(
        text = text,
        color = color,
        fontSize = 9.sp,
        fontWeight = FontWeight.Black,
        modifier = Modifier
            .clip(RoundedCornerShape(4.dp))
            .background(color.copy(alpha = 0.15f))
            .padding(horizontal = 6.dp, vertical = 3.dp),
    )
}

@Composable
private fun ProfileActionRow(
    isOwnProfile: Boolean,
    isFollowing: Boolean,
    isBlocked: Boolean,
    isThrottled: Boolean,
    canZap: Boolean,
    zapSats: Int,
    onCompose: () -> Unit,
    onEditProfile: () -> Unit,
    onFollow: () -> Unit,
    onMessage: () -> Unit,
    onBlock: () -> Unit,
    onThrottle: () -> Unit,
    onZap: () -> Unit,
) {
    val colors = LocalNostrVaultColors.current
    Row(
        horizontalArrangement = Arrangement.spacedBy(10.dp),
        modifier = Modifier
            .fillMaxWidth()
            .horizontalScroll(rememberScrollState())
            .padding(horizontal = 16.dp, vertical = 4.dp),
    ) {
        if (isOwnProfile) {
            ActionChip("Post", NostrVaultIcons.Create, Color.White, colors.primary, onClick = onCompose)
            ActionChip("Edit", NostrVaultIcons.Edit, colors.primary, colors.primary.copy(alpha = 0.12f), onClick = onEditProfile)
        } else {
            ActionChip(
                if (isFollowing) "Unfollow" else "Follow",
                NostrVaultIcons.PersonAdd,
                if (isFollowing) Color.White else colors.primary,
                if (isFollowing) colors.primary else colors.primary.copy(alpha = 0.12f),
                onClick = onFollow,
            )
            ActionChip("Message", NostrVaultIcons.Chat, colors.primary, colors.primary.copy(alpha = 0.12f), onClick = onMessage)
            ActionChip(
                if (isBlocked) "Unblock" else "Block",
                NostrVaultIcons.Blocked,
                if (isBlocked) Color(0xFFFF9800) else Color(0xFFE53935),
                (if (isBlocked) Color(0xFFFF9800) else Color(0xFFE53935)).copy(alpha = 0.12f),
                onClick = onBlock,
            )
            // Slow Down keeps this person to a few posts in the feed (Settings → Blocked lists them).
            val throttleColor = if (isThrottled) Color(0xFF2196F3) else SecondaryText
            ActionChip(
                if (isThrottled) "Speed Up" else "Slow Down",
                Icons.Filled.Speed,
                throttleColor,
                throttleColor.copy(alpha = 0.12f),
                onClick = onThrottle,
                description = if (isThrottled) "Remove speed limit" else "Slow down posts",
            )
            if (canZap) {
                ActionChip("Zap $zapSats", NostrVaultIcons.Zap, Color(0xFFFF9800), Color(0xFFFF9800).copy(alpha = 0.15f), onClick = onZap)
            }
        }
    }
}

@Composable
private fun ActionChip(
    label: String,
    icon: androidx.compose.ui.graphics.vector.ImageVector,
    contentColor: Color,
    background: Color,
    onClick: () -> Unit,
    description: String = label,
) {
    Row(
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(6.dp),
        modifier = Modifier
            .clip(RoundedCornerShape(6.dp))
            .background(background)
            .clickable(onClick = onClick)
            .padding(horizontal = 12.dp, vertical = 7.dp),
    ) {
        Icon(icon, contentDescription = description, tint = contentColor, modifier = Modifier.size(14.dp))
        Text(label, color = contentColor, fontSize = 13.sp, fontWeight = FontWeight.SemiBold)
    }
}

@Composable
private fun ProfileStatsRow(
    notes: Int,
    media: Int,
    following: Int?,
    followers: Int?,
    isOwnProfile: Boolean,
) {
    Row(
        horizontalArrangement = Arrangement.SpaceEvenly,
        modifier = Modifier
            .fillMaxWidth()
            .padding(horizontal = 16.dp, vertical = 12.dp),
    ) {
        ProfileStat(shortInt(notes), "Notes")
        ProfileStat(shortInt(media), "Media")
        ProfileStat(following?.let { shortInt(it) } ?: "—", "Following")
        if (!isOwnProfile) {
            ProfileStat(followers?.let { shortInt(it) } ?: "∞", "Followers")
        }
    }
}

@Composable
private fun ProfileStat(value: String, label: String) {
    Column(horizontalAlignment = Alignment.CenterHorizontally) {
        Text(value, color = PrimaryText, fontSize = 18.sp, fontWeight = FontWeight.Bold)
        Text(label, color = SecondaryText, fontSize = 12.sp)
    }
}

private fun shortInt(n: Int): String = when {
    n >= 1_000_000 -> String.format("%.1fM", n / 1_000_000.0)
    n >= 1_000 -> String.format("%.1fk", n / 1_000.0)
    else -> n.toString()
}

@Composable
private fun ProfileIdentityRows(
    lightning: String?,
    website: String?,
    onCopyLightning: () -> Unit,
) {
    val colors = LocalNostrVaultColors.current
    val uriHandler = androidx.compose.ui.platform.LocalUriHandler.current
    if (lightning == null && website == null) return
    Column(modifier = Modifier.fillMaxWidth()) {
        lightning?.let {
            IdentityRow(NostrVaultIcons.Zap, "LIGHTNING", it, Color(0xFFFF9800), onClick = onCopyLightning)
        }
        website?.let {
            val display = it.removePrefix("https://").removePrefix("http://")
            IdentityRow(NostrVaultIcons.Globe, "WEBSITE", display, colors.primary, onClick = {
                val url = if (it.startsWith("http")) it else "https://$it"
                runCatching { uriHandler.openUri(url) }
            })
        }
    }
}

@Composable
private fun IdentityRow(
    icon: androidx.compose.ui.graphics.vector.ImageVector,
    label: String,
    value: String,
    tint: Color,
    onClick: () -> Unit,
) {
    Row(
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(12.dp),
        modifier = Modifier
            .fillMaxWidth()
            .clickable(onClick = onClick)
            .padding(horizontal = 16.dp, vertical = 10.dp),
    ) {
        Icon(icon, contentDescription = label, tint = tint, modifier = Modifier.size(16.dp))
        Column(modifier = Modifier.weight(1f)) {
            Text(label, color = SecondaryText, fontSize = 9.sp, fontWeight = FontWeight.Black)
            Text(value, color = PrimaryText, fontSize = 13.sp, maxLines = 1)
        }
    }
}

// iOS ProfileView.sectionTabBar: uppercase heavy labels + mono counts over a
// 2dp underline on the selected section.
@Composable
private fun ProfileSectionTabs(
    selected: ProfileSection,
    counts: ProfileCounts,
    /** Counts for the tabs that are not notes: Shop, Articles, diVines, Music. */
    extraCounts: Map<ProfileSection, Int>,
    shown: (ProfileSection) -> Boolean,
    onSelect: (ProfileSection) -> Unit,
) {
    val colors = LocalNostrVaultColors.current
    fun countFor(s: ProfileSection): Int = when (s) {
        ProfileSection.NOTES -> counts.notes
        ProfileSection.MEDIA -> counts.media
        ProfileSection.REPLIES -> counts.replies
        ProfileSection.TAGGED -> counts.tagged
        else -> extraCounts[s] ?: 0
    }
    val sections = ProfileSection.entries.filter(shown)
    Row(modifier = Modifier
        .fillMaxWidth()
        .padding(horizontal = 16.dp)) {
        sections.forEach { section ->
            val isSelected = section == selected
            val c = countFor(section)
            val label = if (c > 0) shortInt(c) else null
            Column(
                horizontalAlignment = Alignment.CenterHorizontally,
                modifier = Modifier
                    .weight(1f)
                    .clickable(onClickLabel = section.displayName) { onSelect(section) }
                    .semantics { contentDescription = section.displayName + (label?.let { ", $it" } ?: "") }
                    .padding(top = 4.dp),
            ) {
                // Icons, as the feed types show them: icon and count, or the
                // icon alone on a tab too narrow for the count (iOS #280).
                BoxWithConstraints(contentAlignment = Alignment.Center, modifier = Modifier.fillMaxWidth().height(20.dp)) {
                    val fitsCount = label != null && maxWidth >= ProfileTabFiller.tabWidthWithCount(label.length)
                    Row(
                        verticalAlignment = Alignment.CenterVertically,
                        horizontalArrangement = Arrangement.spacedBy(4.dp),
                    ) {
                        Icon(
                            section.icon,
                            contentDescription = null,
                            tint = if (isSelected) colors.primary else SecondaryText,
                            modifier = Modifier.size(17.dp),
                        )
                        if (fitsCount && label != null) {
                            Text(
                                text = label,
                                fontSize = 10.sp,
                                fontWeight = FontWeight.SemiBold,
                                fontFamily = FontFamily.Monospace,
                                maxLines = 1,
                                softWrap = false,
                                color = SecondaryText,
                            )
                        }
                    }
                }
                Spacer(Modifier.height(6.dp))
                Box(
                    modifier = Modifier
                        .fillMaxWidth()
                        .height(2.dp)
                        .background(if (isSelected) colors.primary else Color.Transparent),
                )
            }
        }
    }
}

/** The feed types' own icons, so a tab reads the same as the feed it matches. */
private val ProfileSection.icon: androidx.compose.ui.graphics.vector.ImageVector
    get() = when (this) {
        ProfileSection.NOTES -> NostrVaultIcons.Chat
        ProfileSection.MEDIA -> NostrVaultIcons.Media
        ProfileSection.REPLIES -> NostrVaultIcons.Reply
        ProfileSection.ARTICLES -> NostrVaultIcons.Articles
        ProfileSection.DIVINES -> NostrVaultIcons.Reels
        ProfileSection.MUSIC -> NostrVaultIcons.Music
        ProfileSection.TAGGED -> NostrVaultIcons.At
        ProfileSection.SHOP -> NostrVaultIcons.Marketplace
    }

/** One of this person's articles: cover, title, summary and date. Opens the reader. */
@Composable
private fun ProfileArticleRow(note: com.nostrvault.data.model.FeedNote, onClick: () -> Unit) {
    val meta = remember(note.id, note.tags) { com.nostrvault.data.model.ArticleMeta.from(note) }
    Column(
        modifier = Modifier
            .fillMaxWidth()
            .clickable(onClick = onClick)
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
            overflow = androidx.compose.ui.text.style.TextOverflow.Ellipsis,
        )
        meta.summary?.let {
            Spacer(Modifier.height(6.dp))
            Text(
                text = it,
                color = SecondaryText,
                fontSize = 14.sp,
                lineHeight = 19.sp,
                maxLines = 3,
                overflow = androidx.compose.ui.text.style.TextOverflow.Ellipsis,
            )
        }
        Spacer(Modifier.height(8.dp))
        Text(
            text = buildString {
                append(java.text.DateFormat.getDateInstance(java.text.DateFormat.MEDIUM).format(meta.publishedAt))
                com.nostrvault.data.model.ArticleMeta.readingTimeMinutes(note.content)?.let { append(" · $it min read") }
            },
            color = TertiaryText,
            fontSize = 12.sp,
        )
    }
}

/** A diVine's poster, 9:16, with a play mark. */
@Composable
private fun DiVineTile(reel: com.nostrvault.data.model.Reel, onClick: () -> Unit, modifier: Modifier = Modifier) {
    Box(
        contentAlignment = Alignment.BottomStart,
        modifier = modifier
            .aspectRatio(9f / 16f)
            .clip(RoundedCornerShape(6.dp))
            .background(Color.Black)
            .clickable(onClickLabel = reel.title ?: "diVine", onClick = onClick),
    ) {
        reel.posterUrl?.let { poster ->
            AsyncImage(
                model = poster,
                contentDescription = reel.title,
                contentScale = ContentScale.Crop,
                modifier = Modifier.matchParentSize(),
            )
        }
        Icon(
            NostrVaultIcons.PlayArrow,
            contentDescription = null,
            tint = Color.White,
            modifier = Modifier.padding(6.dp).size(16.dp),
        )
    }
}

/** This person's diVines full screen, one page each, the visible one playing. */
@Composable
private fun DiVineViewer(reels: List<com.nostrvault.data.model.Reel>, startIndex: Int, onDismiss: () -> Unit) {
    val pagerState = rememberPagerState(initialPage = startIndex, pageCount = { reels.size })
    androidx.activity.compose.BackHandler(onBack = onDismiss)
    Box(
        modifier = Modifier
            .fillMaxSize()
            .background(Color.Black),
    ) {
        androidx.compose.foundation.pager.VerticalPager(state = pagerState, modifier = Modifier.fillMaxSize()) { page ->
            Box(contentAlignment = Alignment.Center, modifier = Modifier.fillMaxSize()) {
                // Only the visible page gets a player, to keep memory at one instance.
                if (page == pagerState.currentPage) {
                    com.nostrvault.ui.components.VideoPlayer(uri = reels[page].videoUrl, modifier = Modifier.fillMaxSize())
                } else {
                    reels[page].posterUrl?.let {
                        AsyncImage(model = it, contentDescription = null, contentScale = ContentScale.Fit, modifier = Modifier.fillMaxSize())
                    }
                }
            }
        }
        IconButton(
            onClick = onDismiss,
            modifier = Modifier
                .align(Alignment.TopEnd)
                .statusBarsPadding()
                .padding(12.dp),
        ) {
            Icon(NostrVaultIcons.Dismiss, "Close", tint = Color.White, modifier = Modifier.size(28.dp))
        }
    }
}

/**
 * Whether a media link is worth copying: anything but this phone's own
 * relay (127.0.0.1 / localhost), which nobody else can open.
 * iOS: ConfigService.hasExternalShareURL.
 */
internal fun isShareableMediaUrl(url: String): Boolean {
    val host = runCatching { java.net.URI(url).host }.getOrNull()?.lowercase() ?: return false
    return host != "127.0.0.1" && host != "localhost" && host != "0.0.0.0"
}

@Composable
private fun MediaViewerOverlay(
    urls: List<String>,
    startIndex: Int,
    onDismiss: () -> Unit,
    // The feed viewer's save: MediaStore, the same toast lines.
    saver: com.nostrvault.ui.components.FeedMediaMirrorViewModel = hiltViewModel(),
) {
    val pagerState = rememberPagerState(initialPage = startIndex, pageCount = { urls.size })
    val context = LocalContext.current
    val clipboard = LocalClipboardManager.current
    val saveState by saver.saveState.collectAsState()
    val currentUrl = urls[pagerState.currentPage.coerceIn(0, urls.lastIndex)]
    LaunchedEffect(currentUrl) { saver.onOpen(currentUrl) }
    Box(
        modifier = Modifier
            .fillMaxSize()
            .background(Color.Black.copy(alpha = 0.95f))
            .clickable(onClick = onDismiss),
    ) {
        HorizontalPager(state = pagerState, modifier = Modifier.fillMaxSize()) { page ->
            Box(contentAlignment = Alignment.Center, modifier = Modifier.fillMaxSize()) {
                AsyncImage(
                    model = urls[page],
                    contentDescription = null,
                    contentScale = ContentScale.Fit,
                    modifier = Modifier.fillMaxWidth(),
                )
            }
        }
        IconButton(
            onClick = onDismiss,
            modifier = Modifier
                .align(Alignment.TopEnd)
                .statusBarsPadding()
                .padding(12.dp),
        ) {
            Icon(NostrVaultIcons.Dismiss, "Close", tint = Color.White, modifier = Modifier.size(28.dp))
        }
        // Copy link and Save to gallery, as iOS's profile viewer offers.
        Row(
            horizontalArrangement = Arrangement.spacedBy(8.dp),
            modifier = Modifier
                .align(Alignment.TopStart)
                .statusBarsPadding()
                .padding(12.dp),
        ) {
            if (isShareableMediaUrl(currentUrl)) {
                IconButton(
                    onClick = {
                        clipboard.setText(AnnotatedString(currentUrl))
                        Toast.makeText(context, "Link copied", Toast.LENGTH_SHORT).show()
                    },
                    modifier = Modifier.clip(RoundedCornerShape(8.dp)).background(Color.White.copy(alpha = 0.1f)),
                ) {
                    Icon(NostrVaultIcons.Copy, "Copy link", tint = Color.White, modifier = Modifier.size(20.dp))
                }
            }
            val saving = saveState == com.nostrvault.ui.components.FeedMediaMirrorViewModel.SaveState.Saving
            val saved = saveState == com.nostrvault.ui.components.FeedMediaMirrorViewModel.SaveState.Saved
            IconButton(
                onClick = {
                    saver.saveToGallery(currentUrl) { Toast.makeText(context, it, Toast.LENGTH_SHORT).show() }
                },
                enabled = !saving && !saved,
                modifier = Modifier.clip(RoundedCornerShape(8.dp)).background(Color.White.copy(alpha = 0.1f)),
            ) {
                if (saving) {
                    CircularProgressIndicator(color = Color.White, strokeWidth = 2.dp, modifier = Modifier.size(18.dp))
                } else {
                    Icon(
                        if (saved) NostrVaultIcons.Check else NostrVaultIcons.Import,
                        if (saved) "Saved to gallery" else "Save to gallery",
                        tint = Color.White, modifier = Modifier.size(20.dp),
                    )
                }
            }
        }
    }
}
