package com.nostrvault.ui.screens

import androidx.compose.animation.animateContentSize
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.draw.drawBehind
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.nostrvault.data.model.*
import com.nostrvault.ui.components.*
import com.nostrvault.ui.theme.*
import kotlinx.coroutines.flow.*
import java.util.*

// ── Threaded reply node (recursive) ─────────────────────────────
// Matches iOS ThreadedReplyNode: recursive tree rendering with depth-based
// collapsing, focus highlight, and thread connector lines. This is the full
// mode; the condensed toggle swaps the replies for ThreadCondensedLine rows.

/**
 * What a reply's overflow menu asked for. One parameter through the recursive
 * reply tree instead of three, and the confirmation dialogs stay at screen
 * level where they already are.
 */
internal enum class Moderation { REPORT, BLOCK, DELETE }

private const val COLLAPSE_DEPTH = 3

/**
 * The thread view's condensed mode: one card of lines, drawn the way the
 * threaded feed draws a conversation ([FeedThreadCard]). iOS: `.threadCard()`.
 */
@Composable
internal fun CondensedThreadCard(content: @Composable ColumnScope.() -> Unit) {
    val isOled = LocalOledMode.current
    val themeColor = LocalNostrVaultColors.current.primary
    Column(
        verticalArrangement = Arrangement.spacedBy(2.dp),
        modifier = Modifier
            .fillMaxWidth()
            .padding(horizontal = 10.dp, vertical = 4.dp)
            .background(SecondaryGroupedBg, RoundedCornerShape(12.dp))
            .border(
                width = if (isOled) 1.dp else 0.5.dp,
                color = themeColor.copy(alpha = if (isOled) 0.30f else 0.15f),
                shape = RoundedCornerShape(12.dp),
            )
            .padding(vertical = 8.dp, horizontal = 6.dp),
        content = content,
    )
}

/**
 * One condensed line, as the threaded feed draws it: a bare repost shows the
 * note it carries, credited to its author. iOS: `NoteDetailView.condensedLine`.
 */
@Composable
internal fun ThreadCondensedLine(
    note: FeedNote,
    depth: Int,
    replyCount: Int,
    viewModel: NoteDetailViewModel,
    profiles: Map<String, FeedProfile>,
    onProfileClick: (String) -> Unit,
    /** The avatar's quick menu item for the Web of Trust map. */
    onTrustWeb: (String) -> Unit,
    onTap: () -> Unit,
) {
    val original = note.repostedEventId?.takeIf { note.isBareRepost }
        ?.let(viewModel::findNote)?.takeIf { it.kind != 6 }
    val shown = original?.let { note.withRepostedOriginal(it) } ?: note
    val stats = viewModel.statsFor(note.effectiveEventId)
    CondensedNoteLine(
        note = shown,
        profile = viewModel.profileFor(shown.pubkey),
        profiles = profiles,
        depth = depth,
        style = CondensedLineStyle.PLAIN,
        replyCount = replyCount,
        mediaURLs = shown.mediaURLs,
        engagement = CondensedEngagement(
            reactions = if (LocalZapsOnlyMode.current) 0 else stats?.reactions ?: 0,
            reposts = stats?.reposts ?: 0,
        ),
        onProfileClick = onProfileClick,
        // The quick menu, as on this screen's full notes (iOS CondensedNoteLine).
        avatarMenu = viewModel.avatarMenu,
        onTrustWeb = onTrustWeb,
        onTap = onTap,
    )
}

@Composable
internal fun ThreadedReplyNode(
    reply: FeedNote,
    /** The replies the thread shows (blocked, spam and folded ones already out). */
    pool: List<FeedNote>,
    depth: Int,
    focusedNoteId: String,
    themeColor: androidx.compose.ui.graphics.Color,
    viewModel: NoteDetailViewModel,
    expandedEngagement: Boolean,
    perNoteEngagement: Map<String, EngagementDetails>,
    profiles: Map<String, FeedProfile>,
    onProfileClick: (String) -> Unit,
    onNoteClick: (String) -> Unit,
    /** Where a quoted long-form post opens; the note screen would show its Markdown source. */
    onArticleClick: (String) -> Unit,
    onFocus: (String) -> Unit,
    onReply: (String) -> Unit,
    onQuote: (String) -> Unit,
    onZapNote: (FeedNote) -> Unit,
    onBroadcastNote: (FeedNote) -> Unit,
    /** Opens the Web of Trust map for an author. */
    onTrustWeb: (String) -> Unit,
    onModerateNote: (FeedNote, Moderation) -> Unit,
    onLongPressLikeNote: (FeedNote) -> Unit,
    /** A pill in a note's engagement row: open that list for that note. */
    onEngagementClick: (EngagementSheetKind, String) -> Unit,
    modifier: Modifier = Modifier,
) {
    // Keyed on the pool too: late-arriving replies (refocus fetch,
    // pull-to-refresh) must recompute each node's children.
    val childReplies = remember(reply.id, pool) { pool.filter { it.parentEventId == reply.id } }
    val isFocusedReply = reply.id == focusedNoteId
    val quotedNotesCache by viewModel.quotedNotesCache.collectAsState()
    val quotedNotesMap = remember(reply.id, reply.quotedEventIds, quotedNotesCache) {
        reply.quotedEventIds.mapNotNull { qid ->
            viewModel.quotedNoteFor(qid)?.let { qid to it }
        }.toMap()
    }

    Column(
        modifier = modifier.animateContentSize(animationSpec = Motion.panel()),
    ) {
        // The reply itself
        NoteCard(
            note = reply,
            avatarMenu = viewModel.avatarMenu,
            profile = viewModel.profileFor(reply.pubkey),
            profiles = profiles,
            quotedNotes = quotedNotesMap,
            isLiked = viewModel.isLiked(reply.effectiveEventId),
            isReposted = viewModel.isReposted(reply.effectiveEventId),
            isFocused = isFocusedReply,
            onNoteClick = { onFocus(reply.id) },
            onArticleClick = onArticleClick,
            onProfileClick = onProfileClick,
            onLike = viewModel::likeNote,
            onRepost = viewModel::repostNote,
            onQuote = onQuote,
            onReply = onReply,
            onZap = { onZapNote(reply) },
            onBroadcast = { onBroadcastNote(reply) },
            onTrustWeb = if (viewModel.isOwnNote(reply.effectiveAuthor)) null else onTrustWeb,
            isOwnNote = viewModel.isOwnNote(reply.pubkey),
            onReport = { onModerateNote(reply, Moderation.REPORT) },
            onBlock = { onModerateNote(reply, Moderation.BLOCK) },
            onDelete = { onModerateNote(reply, Moderation.DELETE) },
            onLongPressLike = { onLongPressLikeNote(reply) },
        )

        // Per-note engagement when thread stats are on: emoji pills, zap
        // sats and reposts, each opening its list (iOS ThreadNoteEngagementRow).
        // The focused one is left out, as on iOS: the hero card shows it.
        // Data is the thread's one batch fetch, nothing per row.
        if (expandedEngagement && !isFocusedReply) {
            perNoteEngagement[reply.id]?.let { details ->
                ThreadNoteEngagementRow(
                    details = details,
                    onClick = { kind -> onEngagementClick(kind, reply.id) },
                )
            }
        }

        // Child replies
        if (childReplies.isNotEmpty()) {
            if (depth >= COLLAPSE_DEPTH) {
                // Collapse deep threads — matches iOS "Show X more replies" pill
                Row(
                    verticalAlignment = Alignment.CenterVertically,
                    modifier = Modifier
                        .padding(start = 16.dp, top = 4.dp, bottom = 4.dp)
                        .clickable { onFocus(reply.id) }
                        .background(themeColor.copy(alpha = 0.1f), RoundedCornerShape(8.dp))
                        .padding(vertical = 6.dp, horizontal = 12.dp),
                ) {
                    Icon(
                        imageVector = NostrVaultIcons.Navigate,
                        contentDescription = null,
                        tint = themeColor,
                        modifier = Modifier.size(11.dp),
                    )
                    Spacer(Modifier.width(6.dp))
                    Text(
                        text = "Show ${childReplies.size} more ${if (childReplies.size == 1) "reply" else "replies"}",
                        color = themeColor,
                        fontSize = 12.sp,
                        fontWeight = FontWeight.Bold,
                    )
                }
            } else {
                // Render children with connector line (matches iOS HStack + Rectangle).
                // Drawn behind the column, not as a fillMaxHeight sibling: that
                // needed an intrinsic-height pass through every nested note.
                Column(
                    verticalArrangement = Arrangement.spacedBy(8.dp),
                    modifier = Modifier
                        .padding(start = 8.dp)
                        .drawBehind {
                            val inset = 2.dp.toPx()
                            drawRect(
                                color = themeColor.copy(alpha = 0.25f),
                                topLeft = Offset(0f, inset),
                                size = Size(1.5.dp.toPx(), (size.height - 2 * inset).coerceAtLeast(0f)),
                            )
                        }
                        .padding(start = 7.5.dp),
                ) {
                    for (child in childReplies) {
                        ThreadedReplyNode(
                            reply = child,
                            pool = pool,
                            depth = depth + 1,
                            focusedNoteId = focusedNoteId,
                            themeColor = themeColor,
                            viewModel = viewModel,
                            expandedEngagement = expandedEngagement,
                            perNoteEngagement = perNoteEngagement,
                            profiles = profiles,
                            onProfileClick = onProfileClick,
                            onNoteClick = onNoteClick,
                            onArticleClick = onArticleClick,
                            onFocus = onFocus,
                            onReply = onReply,
                            onQuote = onQuote,
                            onZapNote = onZapNote,
                            onBroadcastNote = onBroadcastNote,
                            onTrustWeb = onTrustWeb,
                            onModerateNote = onModerateNote,
                            onLongPressLikeNote = onLongPressLikeNote,
                            onEngagementClick = onEngagementClick,
                        )
                    }
                }
            }
        }
    }
}
