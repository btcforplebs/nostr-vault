package com.nostrvault.ui.screens.feed

import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.*
import androidx.compose.material3.pulltorefresh.PullToRefreshBox
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.platform.LocalConfiguration
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.hilt.navigation.compose.hiltViewModel
import com.nostrvault.data.model.FeedDashboardSnapshot
import com.nostrvault.data.model.FeedMode
import com.nostrvault.data.model.FeedProfile
import com.nostrvault.data.model.LiveStream
import com.nostrvault.ui.components.AvatarImage
import com.nostrvault.ui.theme.*

/**
 * The feed dashboard: what your follows did in the last 24 hours. Activity
 * only; feed settings live in Settings > Feed. Port of iOS FeedDashboardView.
 */
@OptIn(ExperimentalMaterial3Api::class, ExperimentalLayoutApi::class)
@Composable
fun FeedDashboardScreen(
    onBack: () -> Unit,
    /** Called after the feed was switched; returns to it. */
    onOpenFeed: () -> Unit,
    onProfileClick: (String) -> Unit,
    onNoteClick: (String) -> Unit,
    onHashtagClick: (String) -> Unit,
    /** Opens the Relay tab: on Zaps Received, on Followers, or as it was. */
    onOpenVault: (VaultTarget) -> Unit,
    viewModel: FeedDashboardViewModel = hiltViewModel(),
) {
    val snapshot by viewModel.snapshot.collectAsState()
    val isLoading by viewModel.isLoading.collectAsState()
    val followSetIsEmpty by viewModel.followSetIsEmpty.collectAsState()
    val profiles by viewModel.profiles.collectAsState()
    val events by viewModel.loadedEventsCount.collectAsState()
    val wot by viewModel.wotPubkeys.collectAsState()
    // Four across only where it fits; a phone gets 2×2 so nothing is cut off.
    val isWide = LocalConfiguration.current.screenWidthDp >= 600
    val openFeed: (FeedMode) -> Unit = { mode ->
        viewModel.openOnFollowing(mode)
        onOpenFeed()
    }

    Scaffold(
        topBar = {
            TopAppBar(
                title = {
                    Column {
                        Text("Dashboard")
                        Text(
                            if (isLoading) "Updating…" else "Your network, last 24 hours",
                            style = MaterialTheme.typography.labelMedium,
                            color = SecondaryText,
                        )
                    }
                },
                navigationIcon = {
                    IconButton(onClick = onBack) { Icon(NostrVaultIcons.Back, contentDescription = "Back") }
                },
                colors = TopAppBarDefaults.topAppBarColors(
                    containerColor = WindowBackground,
                    titleContentColor = PrimaryText,
                    navigationIconContentColor = PrimaryText,
                ),
            )
        },
        containerColor = WindowBackground,
    ) { padding ->
        PullToRefreshBox(
            isRefreshing = isLoading && snapshot != null,
            onRefresh = viewModel::refresh,
            modifier = Modifier.fillMaxSize().padding(padding),
        ) {
            Column(
                modifier = Modifier
                    .fillMaxSize()
                    .verticalScroll(rememberScrollState())
                    .padding(16.dp),
                verticalArrangement = Arrangement.spacedBy(20.dp),
            ) {
                val s = snapshot
                when {
                    followSetIsEmpty -> CenterNote("Follow some people and their day shows up here.")
                    s == null -> {
                        Column(Modifier.fillMaxWidth().padding(top = 80.dp), horizontalAlignment = Alignment.CenterHorizontally) {
                            CircularProgressIndicator(color = SecondaryText, strokeWidth = 2.dp, modifier = Modifier.size(24.dp))
                            Spacer(Modifier.height(12.dp))
                            Text("Looking at your network's last 24 hours…", style = MaterialTheme.typography.bodySmall, color = SecondaryText)
                        }
                    }
                    else -> {
                        StatsGrid(s, isWide, openFeed, onOpenVault)
                        if (s.live.isNotEmpty()) LiveCard(s.live, profiles) { openFeed(FeedMode.LIVE) }
                        if (s.mostActive.isNotEmpty()) MostActiveCard(s.mostActive, profiles, isWide, onProfileClick) { openFeed(FeedMode.FOLLOWING) }
                        if (s.popular.isNotEmpty()) PopularCard(s.popular, profiles, onNoteClick)
                        if (s.trending.isNotEmpty()) {
                            DashCard("Trending in your circle", NostrVaultIcons.TagIcon, Color(0xFF0A84FF)) {
                                FlowRow(horizontalArrangement = Arrangement.spacedBy(8.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
                                    s.trending.forEach { tag ->
                                        Row(
                                            Modifier
                                                .clip(CircleShape)
                                                .background(LocalNostrVaultColors.current.primary.copy(alpha = 0.14f))
                                                .clickable { onHashtagClick(tag.id) }
                                                .padding(horizontal = 10.dp, vertical = 6.dp)
                                                .semantics { contentDescription = "#${tag.id}, ${tag.count} people" },
                                            verticalAlignment = Alignment.CenterVertically,
                                        ) {
                                            Text("#${tag.id}", style = MaterialTheme.typography.bodyMedium, color = PrimaryText)
                                            Spacer(Modifier.width(4.dp))
                                            Text("${tag.count}", style = MaterialTheme.typography.labelSmall, color = SecondaryText)
                                        }
                                    }
                                }
                            }
                        }
                        if (s.tiles.isNotEmpty()) TilesCard(s.tiles, isWide, openFeed)
                        VaultRow(events, wot.size) { onOpenVault(VaultTarget.VAULT) }
                    }
                }
            }
        }
    }
}

enum class VaultTarget { VAULT, ZAPS, FOLLOWERS }

@Composable
private fun StatsGrid(
    s: FeedDashboardSnapshot,
    isWide: Boolean,
    openFeed: (FeedMode) -> Unit,
    onOpenVault: (VaultTarget) -> Unit,
) {
    val stats = listOf<@Composable (Modifier) -> Unit>(
        { m -> StatTile(s.posts.toLong(), if (s.posts == 1) "post" else "posts", NostrVaultIcons.Reply, Color(0xFF0A84FF), m) { openFeed(FeedMode.FOLLOWING) } },
        { m -> StatTile(s.activePeople.toLong(), "people posted", NostrVaultIcons.People, Color(0xFF30D158), m) { openFeed(FeedMode.FOLLOWING) } },
        { m -> StatTile(s.satsReceived, "sats to you", NostrVaultIcons.Zap, Color(0xFFFF9F0A), m) { onOpenVault(VaultTarget.ZAPS) } },
        { m ->
            StatTile(
                s.newFollowers.toLong(), if (s.newFollowers == 1) "new follower" else "new followers",
                NostrVaultIcons.PersonAdd, Color(0xFFBF5AF2), m, prefix = if (s.newFollowers > 0) "+" else "",
            ) { onOpenVault(VaultTarget.FOLLOWERS) }
        },
    )
    val perRow = if (isWide) 4 else 2
    Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
        stats.chunked(perRow).forEach { row ->
            Row(horizontalArrangement = Arrangement.spacedBy(10.dp), modifier = Modifier.height(IntrinsicSize.Min)) {
                row.forEach { it(Modifier.weight(1f).fillMaxHeight()) }
            }
        }
    }
}

@Composable
private fun StatTile(
    value: Long,
    label: String,
    icon: ImageVector,
    color: Color,
    modifier: Modifier,
    prefix: String = "",
    onClick: () -> Unit,
) {
    Column(
        modifier
            .clip(RoundedCornerShape(12.dp))
            .background(SecondaryGroupedBg)
            .clickable(onClick = onClick)
            .padding(12.dp)
            .semantics(mergeDescendants = true) {},
        verticalArrangement = Arrangement.spacedBy(6.dp),
    ) {
        Icon(icon, contentDescription = null, tint = color, modifier = Modifier.size(18.dp))
        Text(prefix + compactCount(value), style = MaterialTheme.typography.headlineSmall, fontWeight = FontWeight.Bold,
            color = PrimaryText, maxLines = 1)
        Text(label, style = MaterialTheme.typography.bodySmall, color = SecondaryText, maxLines = 1, overflow = TextOverflow.Ellipsis)
    }
}

@Composable
private fun LiveCard(streams: List<LiveStream>, profiles: Map<String, FeedProfile>, onOpen: () -> Unit) {
    DashCard("Live now", NostrVaultIcons.Live, Color(0xFFFF453A), trailing = "${streams.size}", onMore = onOpen) {
        Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
            streams.take(3).forEach { stream ->
                val profile = profiles[stream.hostPubkey]
                Row(Modifier.fillMaxWidth().clickable(onClick = onOpen), verticalAlignment = Alignment.CenterVertically) {
                    AvatarImage(profile?.pictureURL, stream.hostPubkey, 36.dp, displayName = profile?.bestName)
                    Spacer(Modifier.width(10.dp))
                    Column(Modifier.weight(1f)) {
                        Text(stream.title ?: "Live stream", style = MaterialTheme.typography.bodyMedium, fontWeight = FontWeight.SemiBold,
                            color = PrimaryText, maxLines = 1, overflow = TextOverflow.Ellipsis)
                        Text(nameFor(stream.hostPubkey, profiles), style = MaterialTheme.typography.bodySmall, color = SecondaryText, maxLines = 1)
                    }
                    stream.participants?.takeIf { it > 0 }?.let {
                        Text("$it watching", style = MaterialTheme.typography.labelSmall, color = SecondaryText)
                    }
                }
            }
        }
    }
}

@Composable
private fun MostActiveCard(
    people: List<FeedDashboardSnapshot.Ranked>,
    profiles: Map<String, FeedProfile>,
    isWide: Boolean,
    onProfileClick: (String) -> Unit,
    onMore: () -> Unit,
) {
    val shown = people.take(if (isWide) 12 else 6)
    DashCard("Most active today", NostrVaultIcons.BarChart, Color(0xFF30D158), onMore = onMore) {
        Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy((-6).dp)) {
            shown.forEach { person ->
                val profile = profiles[person.id]
                Box(
                    Modifier
                        .clip(CircleShape)
                        .border(2.dp, SecondaryGroupedBg, CircleShape)
                        .clickable { onProfileClick(person.id) }
                        .semantics { contentDescription = "${nameFor(person.id, profiles)}, ${person.count} posts" },
                ) {
                    AvatarImage(profile?.pictureURL, person.id, 40.dp, displayName = profile?.bestName)
                }
            }
            if (people.size > shown.size) {
                Text("+${people.size - shown.size}", style = MaterialTheme.typography.labelMedium, fontWeight = FontWeight.SemiBold,
                    color = SecondaryText, modifier = Modifier.padding(start = 14.dp))
            }
        }
    }
}

@Composable
private fun PopularCard(
    notes: List<FeedDashboardSnapshot.PopularNote>,
    profiles: Map<String, FeedProfile>,
    onNoteClick: (String) -> Unit,
) {
    DashCard("Popular with your people", NostrVaultIcons.Popular, Color(0xFFFF9F0A)) {
        Column(verticalArrangement = Arrangement.spacedBy(12.dp)) {
            notes.forEachIndexed { index, item ->
                Row(Modifier.fillMaxWidth().clickable { onNoteClick(item.id) }, verticalAlignment = Alignment.Top) {
                    Text("${index + 1}", style = MaterialTheme.typography.titleMedium, color = SecondaryText, modifier = Modifier.widthIn(min = 18.dp))
                    Spacer(Modifier.width(10.dp))
                    Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(3.dp)) {
                        val note = item.note
                        if (note != null) {
                            Text(nameFor(note.pubkey, profiles), style = MaterialTheme.typography.labelMedium, fontWeight = FontWeight.SemiBold,
                                color = SecondaryText, maxLines = 1)
                            Text(note.content.ifBlank { "Post" }, style = MaterialTheme.typography.bodyMedium, color = PrimaryText,
                                maxLines = 2, overflow = TextOverflow.Ellipsis)
                        } else {
                            Text("Loading post…", style = MaterialTheme.typography.bodyMedium, color = SecondaryText)
                        }
                        Row(verticalAlignment = Alignment.CenterVertically) {
                            Icon(NostrVaultIcons.Heart, contentDescription = null, tint = SecondaryText, modifier = Modifier.size(12.dp))
                            Spacer(Modifier.width(4.dp))
                            Text("${item.people} of your follows", style = MaterialTheme.typography.labelSmall, color = SecondaryText)
                        }
                    }
                }
            }
        }
    }
}

@Composable
private fun TilesCard(tiles: List<FeedDashboardSnapshot.Tile>, isWide: Boolean, openFeed: (FeedMode) -> Unit) {
    // A grid, not a side scroll: on a phone a side scroll hides half the tiles.
    DashCard("From your follows", NostrVaultIcons.GridLayout, Color(0xFFBF5AF2)) {
        val perRow = if (isWide) 6 else 3
        Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
            tiles.chunked(perRow).forEach { row ->
                Row(horizontalArrangement = Arrangement.spacedBy(10.dp), modifier = Modifier.height(IntrinsicSize.Min)) {
                    row.forEach { tile ->
                        val mode = tile.mode
                        Column(
                            Modifier
                                .weight(1f)
                                .fillMaxHeight()
                                .heightIn(min = 84.dp)
                                .clip(RoundedCornerShape(10.dp))
                                .background(WindowBackground)
                                .then(if (mode != null) Modifier.clickable { openFeed(mode) } else Modifier)
                                .padding(10.dp)
                                .semantics(mergeDescendants = true) { contentDescription = "${tile.label}, ${tile.count}" },
                            verticalArrangement = Arrangement.spacedBy(4.dp),
                        ) {
                            Row(verticalAlignment = Alignment.CenterVertically) {
                                Icon(mode?.icon ?: NostrVaultIcons.BarChart, contentDescription = null,
                                    tint = LocalNostrVaultColors.current.primary, modifier = Modifier.size(14.dp))
                                Spacer(Modifier.weight(1f))
                                Text("${tile.count}", style = MaterialTheme.typography.titleMedium, fontWeight = FontWeight.SemiBold, color = PrimaryText)
                            }
                            Text(tile.label, style = MaterialTheme.typography.labelMedium, fontWeight = FontWeight.SemiBold,
                                color = PrimaryText, maxLines = 1, overflow = TextOverflow.Ellipsis)
                            Text(tile.preview ?: "", style = MaterialTheme.typography.labelSmall, color = SecondaryText,
                                maxLines = 2, overflow = TextOverflow.Ellipsis)
                        }
                    }
                    // Keep the last row's tiles the same width as the rows above.
                    repeat(perRow - row.size) { Spacer(Modifier.weight(1f)) }
                }
            }
        }
    }
}

@Composable
private fun VaultRow(events: Int, wot: Int, onClick: () -> Unit) {
    Row(
        Modifier
            .fillMaxWidth()
            .clip(RoundedCornerShape(12.dp))
            .background(SecondaryGroupedBg)
            .clickable(onClick = onClick)
            .padding(14.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Icon(NostrVaultIcons.Lock, contentDescription = null, tint = LocalNostrVaultColors.current.primary, modifier = Modifier.size(20.dp))
        Spacer(Modifier.width(10.dp))
        Column(Modifier.weight(1f)) {
            Text("Your vault", style = MaterialTheme.typography.bodyMedium, fontWeight = FontWeight.SemiBold, color = PrimaryText)
            val line = buildList {
                add("${compactCount(events.toLong())} events")
                if (wot > 0) add("Web of Trust ${compactCount(wot.toLong())}")
            }.joinToString(" · ")
            Text(line, style = MaterialTheme.typography.bodySmall, color = SecondaryText)
        }
        Icon(NostrVaultIcons.Navigate, contentDescription = null, tint = TertiaryText, modifier = Modifier.size(16.dp))
    }
}

@Composable
private fun DashCard(
    title: String,
    icon: ImageVector,
    tint: Color,
    trailing: String? = null,
    onMore: (() -> Unit)? = null,
    content: @Composable () -> Unit,
) {
    Column(
        Modifier
            .fillMaxWidth()
            .clip(RoundedCornerShape(12.dp))
            .background(SecondaryGroupedBg)
            .padding(14.dp),
        verticalArrangement = Arrangement.spacedBy(12.dp),
    ) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            Icon(icon, contentDescription = null, tint = tint, modifier = Modifier.size(18.dp))
            Spacer(Modifier.width(6.dp))
            Text(title, style = MaterialTheme.typography.titleMedium, fontWeight = FontWeight.SemiBold, color = PrimaryText)
            trailing?.let {
                Spacer(Modifier.width(6.dp))
                Text(it, style = MaterialTheme.typography.labelMedium, color = SecondaryText)
            }
            Spacer(Modifier.weight(1f))
            if (onMore != null) {
                IconButton(onClick = onMore, modifier = Modifier.size(32.dp)) {
                    Icon(NostrVaultIcons.Navigate, contentDescription = "Open $title", tint = SecondaryText, modifier = Modifier.size(16.dp))
                }
            }
        }
        content()
    }
}

@Composable
private fun CenterNote(text: String) {
    Text(
        text,
        style = MaterialTheme.typography.bodyMedium,
        color = SecondaryText,
        modifier = Modifier.fillMaxWidth().padding(top = 80.dp),
        textAlign = androidx.compose.ui.text.style.TextAlign.Center,
    )
}

private fun nameFor(pubkey: String, profiles: Map<String, FeedProfile>): String =
    profiles[pubkey]?.bestName?.takeIf { it.isNotBlank() } ?: (pubkey.take(8) + "…")

internal fun compactCount(n: Long): String = when {
    n >= 1_000_000 -> String.format(java.util.Locale.US, "%.1fM", n / 1_000_000.0)
    n >= 10_000 -> "${n / 1000}k"
    n >= 1_000 -> String.format(java.util.Locale.US, "%.1fk", n / 1000.0)
    else -> "$n"
}
