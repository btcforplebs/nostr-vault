package com.nostrvault.ui.components

import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp
import com.nostrvault.data.model.FeedNote
import com.nostrvault.data.model.FeedProfile
import java.util.Date

/**
 * Example usage of VaultNoteCard component demonstrating the iOS Vault-style note rendering.
 *
 * This shows how to use the VaultNoteCard with inline engagement metrics instead of
 * action buttons. The design matches the iOS Vault page with overlapping avatars and
 * read-only engagement visualization.
 *
 * Usage in a screen:
 * ```
 * LazyColumn {
 *     items(notes) { note ->
 *         VaultNoteCard(
 *             note = note,
 *             profile = profiles[note.pubkey],
 *             profiles = profiles,
 *             reactors = getReactorsForNote(note.id),
 *             latestReactionDate = getLatestReactionDate(note.id),
 *             reposterPubkeys = getRepostersForNote(note.id),
 *             quoterPubkeys = getQuotersForNote(note.id),
 *             zappers = getZappersForNote(note.id),
 *             noteType = determineNoteType(note.pubkey),
 *             onNoteClick = { noteId -> navigateToNoteDetail(noteId) },
 *             onProfileClick = { pubkey -> navigateToProfile(pubkey) },
 *             onReactorsClick = { showReactorsList(note.id) },
 *             onRepostersClick = { showRepostersList(note.id) },
 *             onQuotersClick = { showQuotersList(note.id) },
 *         )
 *     }
 * }
 * ```
 *
 * ## Layout Modes
 *
 * ### COMPACT mode:
 * - Single row layout
 * - 32dp avatar
 * - 2 lines of text
 * - 60x60 thumbnail on right
 * - NO engagement bar
 * - Ideal for dense lists
 *
 * ### EXPANDED mode:
 * - Full card layout
 * - 40dp avatar
 * - Full content with media
 * - Inline engagement bar with overlapping avatars
 * - Shows reactions, reposts, quotes, zaps
 * - Time ago for latest reaction
 * - Clickable sections for detail views
 *
 * ## Note Types
 *
 * VaultNoteType determines the badge icon and color:
 * - MINE: Purple pencil icon (posts by current user)
 * - WHITELISTED: Green verified icon (posts by followed users)
 * - TAGGED: Blue tag icon (posts where user is mentioned)
 *
 * ## Engagement Data Structure
 *
 * The component expects engagement data in these formats:
 * - reactors: List<Pair<String, String>> - (pubkey, emoji)
 * - reposterPubkeys: List<String> - hex pubkeys
 * - quoterPubkeys: List<String> - hex pubkeys
 * - zappers: List<Pair<String, Long>> - (pubkey, amount in sats)
 *
 * ## Differences from NoteCard
 *
 * Unlike the standard NoteCard, VaultNoteCard:
 * - Shows WHO engaged (with avatars) not just counts
 * - No quick action buttons for replying, sharing
 * - Read-only engagement visualization
 * - No parent note preview inside card
 * - Condensed, cleaner appearance
 * - Designed for vault/relay dashboard contexts
 */
@Composable
fun VaultNoteListExample(
    notes: List<FeedNote>,
    profiles: Map<String, FeedProfile>,
    currentUserPubkey: String,
    whitelistedPubkeys: Set<String>,
    // Engagement data fetchers
    getReactorsForNote: (String) -> List<Pair<String, String>>,
    getLatestReactionDate: (String) -> Date?,
    getRepostersForNote: (String) -> List<String>,
    getQuotersForNote: (String) -> List<String>,
    getZappersForNote: (String) -> List<Pair<String, Long>>,
    // Callbacks
    onNoteClick: (String) -> Unit,
    onProfileClick: (String) -> Unit,
    onReactorsClick: (String) -> Unit,
    onRepostersClick: (String) -> Unit,
    onQuotersClick: (String) -> Unit,
) {
    LazyColumn(
        contentPadding = PaddingValues(horizontal = 16.dp, vertical = 12.dp),
        verticalArrangement = Arrangement.spacedBy(12.dp),
    ) {
        items(notes, key = { it.id }) { note ->
            VaultNoteCard(
                note = note,
                profile = profiles[note.pubkey],
                profiles = profiles,
                reactors = getReactorsForNote(note.id),
                latestReactionDate = getLatestReactionDate(note.id),
                reposterPubkeys = getRepostersForNote(note.id),
                quoterPubkeys = getQuotersForNote(note.id),
                zappers = getZappersForNote(note.id),
                noteType = when {
                    note.pubkey == currentUserPubkey -> VaultNoteType.MINE
                    whitelistedPubkeys.contains(note.pubkey) -> VaultNoteType.WHITELISTED
                    else -> VaultNoteType.TAGGED
                },
                onNoteClick = onNoteClick,
                onProfileClick = onProfileClick,
                onReactorsClick = { onReactorsClick(note.id) },
                onRepostersClick = { onRepostersClick(note.id) },
                onQuotersClick = { onQuotersClick(note.id) },
            )
        }
    }
}

/**
 * Helper function to determine note type based on user relationships.
 */
fun determineNoteType(
    notePubkey: String,
    currentUserPubkey: String,
    whitelistedPubkeys: Set<String>,
): VaultNoteType {
    return when {
        notePubkey == currentUserPubkey -> VaultNoteType.MINE
        whitelistedPubkeys.contains(notePubkey) -> VaultNoteType.WHITELISTED
        else -> VaultNoteType.TAGGED
    }
}
