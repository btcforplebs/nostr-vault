package com.nostrvault.ui.screens.dashboard

import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.outlined.HeartBroken
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
import com.nostrvault.ui.components.reactionDisplayEmoji
import com.nostrvault.ui.components.reactionEmojiSummary
import com.nostrvault.ui.components.VaultNoteCard
import com.nostrvault.ui.components.VaultNoteLayoutMode
import com.nostrvault.ui.components.VaultNoteType
import com.nostrvault.ui.theme.*
import kotlinx.coroutines.*
import kotlinx.coroutines.flow.map
import kotlinx.serialization.json.*

// ═══════════════════════════════════════════════════════════════════
// Likes content
// ═══════════════════════════════════════════════════════════════════

@Composable
internal fun LikesContent(
    notes: List<FeedNote>,
    quotedNotes: Map<String, FeedNote>,
    reactionMap: Map<String, List<Pair<String, String>>>,
    hasLoadedOnce: Boolean,
    isRefreshing: Boolean,
    likesFilter: VaultLikesFilter,
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
    val latestReactionDates by viewModel.latestReactionDates.collectAsState()

    val given = likesFilter == VaultLikesFilter.MY_LIKES
    if (notes.isEmpty() && (isRefreshing || !hasLoadedOnce)) {
        VaultLoadingState("Loading likes...", padding.calculateTopPadding())
    } else if (notes.isEmpty()) {
        VaultEmptyState(
            // heart.slash / heart; Material has no slashed heart, HeartBroken is the nearest.
            icon = if (!given) Icons.Outlined.HeartBroken else NostrVaultIcons.Heart,
            // iOS red → pink; no pink token, so red → the error red ([Tara]).
            gradient = listOf(LikeRed, ErrorRed),
            title = if (!given) "No reactions yet" else "No liked posts",
            hint = if (!given) "Reactions on these notes will appear here" else "Posts you've liked will appear here",
            topPadding = padding.calculateTopPadding(),
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
                    // Under Given the posts are yours to like, not your likers'
                    // (iOS likesList `rowReactors`).
                    reactors = reactionMap[note.id].takeIf { !given } ?: emptyList(),
                    latestReactionDate = latestReactionDates[note.id]?.takeIf { !given }?.let { java.util.Date(it * 1000) },
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
// LikedByRow — shows reactor avatars and "name1, name2 liked"
// ═══════════════════════════════════════════════════════════════════

@Composable
private fun LikedByRow(
    reactors: List<Pair<String, String>>,
    profiles: Map<String, FeedProfile>,
    modifier: Modifier = Modifier,
) {
    val unique = reactors.distinctBy { it.first }.take(5)
    Row(
        verticalAlignment = Alignment.CenterVertically,
        modifier = modifier,
    ) {
        Text(
            text = reactionEmojiSummary(reactors.map { it.second }, limit = 3),
            fontSize = 12.sp,
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
                        .padding(start = (index * 16).dp)
                        .size(22.dp)
                        .clip(CircleShape)
                        .border(1.5.dp, SecondaryGroupedBg, CircleShape)
                        .background(SecondaryGroupedBg, CircleShape),
                )
            }
        }
        Spacer(Modifier.width(6.dp))

        // "name1, name2 liked" (or "reacted" when any reaction isn't a plain heart)
        val names = unique.take(3).map { (pubkey, _) ->
            profiles[pubkey]?.bestName ?: "npub\u2026${pubkey.takeLast(4)}"
        }
        val remaining = unique.size - names.size
        val allHearts = reactors.all { reactionDisplayEmoji(it.second) == "\u2764\ufe0f" }
        val text = buildString {
            append(names.joinToString(", "))
            if (remaining > 0) append(" +$remaining more")
            append(if (allHearts) " liked" else " reacted")
        }
        Text(
            text = text,
            color = SecondaryText,
            fontSize = 13.sp,
            fontWeight = FontWeight.Medium,
            maxLines = 1,
        )
    }
}
