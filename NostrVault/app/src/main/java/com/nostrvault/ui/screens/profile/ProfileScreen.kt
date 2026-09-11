package com.nostrvault.ui.screens.profile

import android.widget.Toast
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.pager.HorizontalPager
import androidx.compose.foundation.pager.rememberPagerState
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.*
import androidx.compose.runtime.*
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
    onNavigateToSettings: () -> Unit = {},
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
    val isLoading by viewModel.isLoading.collectAsState()
    val isLoadingOlder by viewModel.isLoadingOlder.collectAsState()
    val hasMoreNotes by viewModel.hasMoreNotes.collectAsState()
    val hasMoreTagged by viewModel.hasMoreTagged.collectAsState()
    val followersCount by viewModel.followersCount.collectAsState()
    val followingCount by viewModel.followingCount.collectAsState()
    val allProfiles by viewModel.profiles.collectAsState()
    val quotedNotes by viewModel.quotedNotesCache.collectAsState()
    val repostedIds by viewModel.repostedEventIds.collectAsState()
    val toast by viewModel.toast.collectAsState()
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
                        IconButton(onClick = { /* ecash wallet */ }, modifier = Modifier.size(40.dp)) {
                            Icon(NostrVaultIcons.EcashWallet, "Ecash", tint = colors.primary, modifier = Modifier.size(25.dp))
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
        LazyColumn(
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
                    canZap = canZap,
                    zapSats = viewModel.defaultZapSats,
                    onCompose = onCompose,
                    onEditProfile = onEditProfile,
                    onFollow = viewModel::toggleFollow,
                    onMessage = { onNavigateToDMThread(pubkey) },
                    onBlock = viewModel::toggleBlock,
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

            item {
                ProfileSectionTabs(
                    selected = selectedSection,
                    counts = counts,
                    onSelect = viewModel::setSection,
                )
            }

            // ── Section content ──────────────────────────────────────
            if (isLoading && filteredNotes.isEmpty()) {
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
            if (!isLoading && filteredNotes.isNotEmpty() && hasMore) {
                item(key = "load-more-${selectedSection.name}-${filteredNotes.size}") {
                    LaunchedEffect(Unit) { viewModel.loadOlder() }
                    if (isLoadingOlder) {
                        CenteredSpinner(colors.primary)
                    } else {
                        Spacer(Modifier.height(24.dp))
                    }
                }
            }
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
    canZap: Boolean,
    zapSats: Int,
    onCompose: () -> Unit,
    onEditProfile: () -> Unit,
    onFollow: () -> Unit,
    onMessage: () -> Unit,
    onBlock: () -> Unit,
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
        Icon(icon, contentDescription = label, tint = contentColor, modifier = Modifier.size(14.dp))
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
    onSelect: (ProfileSection) -> Unit,
) {
    val colors = LocalNostrVaultColors.current
    fun countFor(s: ProfileSection): Int = when (s) {
        ProfileSection.NOTES -> counts.notes
        ProfileSection.MEDIA -> counts.media
        ProfileSection.REPLIES -> counts.replies
        ProfileSection.TAGGED -> counts.tagged
    }
    Row(modifier = Modifier
        .fillMaxWidth()
        .padding(horizontal = 16.dp)) {
        ProfileSection.entries.forEach { section ->
            val isSelected = section == selected
            val c = countFor(section)
            Column(
                horizontalAlignment = Alignment.CenterHorizontally,
                modifier = Modifier
                    .weight(1f)
                    .clickable { onSelect(section) }
                    .padding(top = 4.dp),
            ) {
                Row(
                    verticalAlignment = Alignment.CenterVertically,
                    horizontalArrangement = Arrangement.spacedBy(5.dp),
                ) {
                    Text(
                        text = section.displayName.uppercase(),
                        fontSize = 11.sp,
                        fontWeight = FontWeight.Black,
                        letterSpacing = 0.6.sp,
                        color = if (isSelected) colors.primary else SecondaryText,
                    )
                    if (c > 0) {
                        Text(
                            text = shortInt(c),
                            fontSize = 11.sp,
                            fontWeight = FontWeight.SemiBold,
                            fontFamily = FontFamily.Monospace,
                            color = SecondaryText,
                        )
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

@Composable
private fun MediaViewerOverlay(
    urls: List<String>,
    startIndex: Int,
    onDismiss: () -> Unit,
) {
    val pagerState = rememberPagerState(initialPage = startIndex, pageCount = { urls.size })
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
    }
}
