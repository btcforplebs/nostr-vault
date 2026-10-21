package com.nostrvault.ui.screens.dashboard

import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.outlined.FindInPage
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.nostrvault.data.model.*
import com.nostrvault.ui.components.VaultNoteCard
import com.nostrvault.ui.components.VaultNoteLayoutMode
import com.nostrvault.ui.components.VaultNoteType
import com.nostrvault.ui.theme.*
import kotlinx.coroutines.*
import kotlinx.serialization.json.*

// ═══════════════════════════════════════════════════════════════════
// Notes content
// ═══════════════════════════════════════════════════════════════════

@Composable
internal fun NotesContent(
    notes: List<FeedNote>,
    /** Notes, Articles or Highlights, for the empty list's words. */
    scope: VaultNoteScope,
    recipesOnly: Boolean,
    /** Articles' and Highlights' "Load older"; null where the list pages on sight or has nothing older. */
    loadOlder: (() -> Unit)?,
    isLoadingOlder: Boolean,
    quotedNotes: Map<String, FeedNote>,
    reactionMap: Map<String, List<Pair<String, String>>>,
    zapMap: Map<String, List<Pair<String, Long>>>,
    repostMap: Map<String, List<String>>,
    quoteMap: Map<String, List<String>>,
    isRefreshing: Boolean,
    hasLoadedOnce: Boolean,
    /** The relay's boot line while it starts, else null (see [relayBootText]). */
    bootText: String?,
    isLoadingMore: Boolean,
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
    val latestReactionDates by viewModel.latestReactionDates.collectAsState()

    if (notes.isEmpty() && (isRefreshing || !hasLoadedOnce || bootText != null)) {
        VaultLoadingState(bootText ?: "Loading notes...", padding.calculateTopPadding())
    } else if (notes.isEmpty()) {
        VaultEmptyState(
            icon = Icons.Outlined.FindInPage, // doc.text.magnifyingglass
            gradient = vaultAccentGradient(),
            title = emptyNotesTitle(scope, recipesOnly),
            hint = emptyNotesHint(scope, recipesOnly),
            topPadding = padding.calculateTopPadding(),
        ) {
            // Nothing loaded yet may still mean something older on the relay.
            if (loadOlder != null) LoadOlderButton(isLoadingOlder, loadOlder)
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
                // Likes, zaps, reposts and quotes only under your own and
                // whitelisted notes (iOS notesList `showEngagement`).
                val showEngagement = noteType != VaultNoteType.TAGGED
                VaultNoteCard(
                    note = note,
                    quotedNotes = quotedNotes,
                    profile = viewModel.profileFor(note.pubkey),
                    profiles = allProfiles,
                    reactors = reactionMap[note.id].takeIf { showEngagement } ?: emptyList(),
                    latestReactionDate = latestReactionDates[note.id]?.takeIf { showEngagement }?.let { java.util.Date(it * 1000) },
                    reposterPubkeys = repostMap[note.id].takeIf { showEngagement } ?: emptyList(),
                    quoterPubkeys = quoteMap[note.id].takeIf { showEngagement } ?: emptyList(),
                    zappers = zapMap[note.id].takeIf { showEngagement } ?: emptyList(),
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

            if (loadOlder != null) {
                item(key = "load-older") {
                    Box(contentAlignment = Alignment.Center, modifier = Modifier.fillMaxWidth()) {
                        LoadOlderButton(isLoadingOlder, loadOlder)
                    }
                }
            } else if (isLoadingMore) {
                item {
                    Box(
                        contentAlignment = Alignment.Center,
                        modifier = Modifier
                            .fillMaxWidth()
                            .padding(16.dp),
                    ) {
                        CircularProgressIndicator(
                            color = colors.primary,
                            modifier = Modifier.size(24.dp),
                        )
                    }
                }
            }
        }
    }
}

/** The empty list's headline for the scope the Vault menu picked. */
private fun emptyNotesTitle(scope: VaultNoteScope, recipesOnly: Boolean): String = when (scope) {
    VaultNoteScope.NOTES -> "No notes found"
    VaultNoteScope.ARTICLES -> if (recipesOnly) "No recipes found" else "No articles found"
    VaultNoteScope.HIGHLIGHTS -> "No highlights found"
}

/**
 * Articles and highlights are rare: an empty list usually means none were
 * published, not that a filter hid them.
 */
private fun emptyNotesHint(scope: VaultNoteScope, recipesOnly: Boolean): String = when (scope) {
    VaultNoteScope.NOTES -> "Try changing your filter settings"
    VaultNoteScope.ARTICLES ->
        if (recipesOnly) "Recipes are articles tagged zapcooking or nostrcooking"
        else "Long-form posts you write or are tagged in land here"
    VaultNoteScope.HIGHLIGHTS -> "Highlights you make or that quote you land here"
}

/** Articles' and Highlights' pager: one older page per tap (iOS loadOlderButton). */
@Composable
private fun LoadOlderButton(isLoading: Boolean, onClick: () -> Unit) {
    val colors = LocalNostrVaultColors.current
    Surface(
        onClick = onClick,
        enabled = !isLoading,
        shape = CircleShape,
        color = colors.primary.copy(alpha = 0.12f),
        modifier = Modifier.padding(top = 8.dp, bottom = 24.dp),
    ) {
        Row(
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(6.dp),
            modifier = Modifier.height(36.dp).padding(horizontal = 16.dp),
        ) {
            if (isLoading) {
                CircularProgressIndicator(color = colors.primary, strokeWidth = 2.dp, modifier = Modifier.size(16.dp))
            } else {
                Icon(NostrVaultIcons.History, contentDescription = null, tint = colors.primary, modifier = Modifier.size(18.dp))
            }
            Text("Load older", color = colors.primary, fontSize = 14.sp, fontWeight = FontWeight.SemiBold)
        }
    }
}
