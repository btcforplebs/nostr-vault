package com.nostrvault.ui.screens.dashboard

import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import coil.compose.AsyncImage
import com.nostrvault.data.model.*
import com.nostrvault.ui.components.VaultNoteCard
import com.nostrvault.ui.components.VaultNoteLayoutMode
import com.nostrvault.ui.components.VaultNoteType
import com.nostrvault.ui.theme.*
import kotlinx.coroutines.*
import kotlinx.coroutines.flow.map
import kotlinx.serialization.json.*
import java.text.NumberFormat

// ═══════════════════════════════════════════════════════════════════
// Zaps content
// ═══════════════════════════════════════════════════════════════════

@Composable
internal fun ZapsContent(
    notes: List<FeedNote>,
    quotedNotes: Map<String, FeedNote>,
    zapMap: Map<String, List<Pair<String, Long>>>,
    hasLoadedOnce: Boolean,
    isRefreshing: Boolean,
    zapsFilter: VaultZapsFilter,
    /** The wallet's history is still being read for Given (one NWC call can take 15s). */
    walletGivenLoading: Boolean,
    listState: androidx.compose.foundation.lazy.LazyListState,
    allProfiles: Map<String, FeedProfile>,
    padding: PaddingValues,
    viewModel: DashboardViewModel,
    onNoteClick: (String) -> Unit,
    onArticleClick: (String) -> Unit,
    onProfileClick: (String) -> Unit,
    /** The row a tapped notification landed on, outlined briefly. */
    focusedEventId: String? = null,
    onReportNote: (FeedNote, String, String) -> Unit,
    onBlockAuthor: (String) -> Unit,
) {
    val colors = LocalNostrVaultColors.current

    // Settle-driven loading: hasLoadedOnce is set either when zaps arrive or by a
    // bounded ~6s settle (armZapsSettle), so the spinner never hangs forever when
    // there are simply no zaps. Don't gate on isRefreshing here. The wallet's
    // history can outlast that settle, so Given keeps spinning while it is read.
    if (notes.isEmpty() && (!hasLoadedOnce || (zapsFilter == VaultZapsFilter.MY_ZAPS && walletGivenLoading))) {
        Box(
            contentAlignment = Alignment.Center,
            modifier = Modifier
                .fillMaxSize()
                .padding(top = padding.calculateTopPadding()),
        ) {
            Column(horizontalAlignment = Alignment.CenterHorizontally) {
                CircularProgressIndicator(
                    color = colors.primary,
                    modifier = Modifier.size(32.dp),
                )
                Spacer(Modifier.height(16.dp))
                Text(
                    text = "Loading zaps...",
                    color = PrimaryText,
                    fontSize = 18.sp,
                    fontWeight = FontWeight.Bold,
                )
                Text(
                    text = "This may take a moment",
                    color = TertiaryText,
                    fontSize = 12.sp,
                )
            }
        }
    } else if (notes.isEmpty()) {
        Box(
            contentAlignment = Alignment.Center,
            modifier = Modifier
                .fillMaxSize()
                .padding(top = padding.calculateTopPadding()),
        ) {
            Column(horizontalAlignment = Alignment.CenterHorizontally) {
                Icon(
                    imageVector = NostrVaultIcons.Zap,
                    contentDescription = null,
                    tint = ZapOrange,
                    modifier = Modifier.size(48.dp),
                )
                Spacer(Modifier.height(12.dp))
                Text(
                    text = if (zapsFilter != VaultZapsFilter.MY_ZAPS) "No zaps yet" else "No zapped posts",
                    color = SecondaryText,
                    fontSize = 16.sp,
                    fontWeight = FontWeight.Bold,
                )
                Text(
                    text = if (zapsFilter != VaultZapsFilter.MY_ZAPS) "Zaps on these notes will appear here" else "Posts you've zapped will appear here",
                    color = TertiaryText,
                    fontSize = 13.sp,
                )
            }
        }
    } else {
        LazyColumn(
            state = listState,
            contentPadding = PaddingValues(
                top = padding.calculateTopPadding(),
                bottom = padding.calculateBottomPadding() + 88.dp,
            ),
            modifier = Modifier.fillMaxSize(),
        ) {
            items(items = notes, key = { it.id }) { note ->
                val noteType = when {
                    note.pubkey == viewModel.currentUserPubkey() -> VaultNoteType.MINE
                    viewModel.isWhitelisted(note.pubkey) -> VaultNoteType.WHITELISTED
                    else -> VaultNoteType.TAGGED
                }
                VaultNoteCard(
                    note = note,
                    quotedNotes = quotedNotes,
                    profile = viewModel.profileFor(note.pubkey),
                    profiles = allProfiles,
                    zappers = zapMap[note.id] ?: emptyList(),
                    noteType = noteType,
                    layoutMode = VaultNoteLayoutMode.EXPANDED,
                    onNoteClick = onNoteClick,
                    onArticleClick = onArticleClick,
                    onProfileClick = onProfileClick,
                    onReport = { reason, description -> onReportNote(note, reason, description) },
                    onBlock = { onBlockAuthor(note.pubkey) },
                    modifier = Modifier
                        .padding(horizontal = 16.dp, vertical = 6.dp)
                        .relayFocusOutline(note.id == focusedEventId),
                )
            }
        }
    }
}

// ═══════════════════════════════════════════════════════════════════
// ZappedByRow — shows zapper avatars, names, and total sats
// ═══════════════════════════════════════════════════════════════════

@Composable
private fun ZappedByRow(
    zappers: List<Pair<String, Long>>,
    profiles: Map<String, FeedProfile>,
    modifier: Modifier = Modifier,
) {
    val unique = zappers.distinctBy { it.first }.take(5)
    val totalSats = zappers.sumOf { it.second }

    Row(
        verticalAlignment = Alignment.CenterVertically,
        modifier = modifier,
    ) {
        Icon(
            imageVector = NostrVaultIcons.Zap,
            contentDescription = null,
            tint = ZapOrange,
            modifier = Modifier.size(11.dp),
        )
        Spacer(Modifier.width(6.dp))

        // Overlapping avatars
        Box {
            unique.forEachIndexed { index, (pubkey, _) ->
                val profile = profiles[pubkey]
                AsyncImage(
                    model = profile?.pictureURL,
                    contentDescription = null,
                    contentScale = ContentScale.Crop,
                    modifier = Modifier
                        .padding(start = (index * 14).dp)
                        .size(20.dp)
                        .clip(CircleShape)
                        .border(1.5.dp, SecondaryGroupedBg, CircleShape)
                        .background(SecondaryGroupedBg, CircleShape),
                )
            }
        }
        Spacer(Modifier.width(6.dp))

        val names = unique.take(3).map { (pubkey, _) ->
            profiles[pubkey]?.bestName ?: "npub\u2026${pubkey.takeLast(4)}"
        }
        val remaining = unique.size - names.size
        val text = buildString {
            append(names.joinToString(", "))
            if (remaining > 0) append(" +$remaining more")
            append(" zapped")
            if (totalSats > 0) {
                val formatted = NumberFormat.getNumberInstance().format(totalSats)
                append(" \u00B7 $formatted sats")
            }
        }
        Text(
            text = text,
            color = SecondaryText,
            fontSize = 12.sp,
            fontWeight = FontWeight.Medium,
            maxLines = 1,
        )
    }
}
