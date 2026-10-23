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
import androidx.compose.ui.geometry.CornerRadius
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.draw.drawBehind
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.graphics.drawscope.clipRect
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.nostrvault.data.model.*
import com.nostrvault.ui.components.*
import com.nostrvault.ui.theme.*
import kotlinx.coroutines.flow.*
import java.util.*

// ── Threaded reply rows ─────────────────────────────────────────
// Matches iOS ThreadedReplyNode: the reply tree with depth-based collapsing,
// focus highlight, and thread connector lines, one lazy row per reply. This
// is the full mode; the condensed toggle swaps the replies for
// ThreadCondensedLine rows.

/**
 * What a reply's overflow menu asked for. One parameter through the recursive
 * reply tree instead of three, and the confirmation dialogs stay at screen
 * level where they already are.
 */
internal enum class Moderation { REPORT, BLOCK, DELETE }

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


/** Where a condensed line sits in its card, which decides the corners it draws. */
internal enum class CardSegment { ONLY, FIRST, MIDDLE, LAST;
    companion object {
        fun of(index: Int, count: Int): CardSegment = when {
            count == 1 -> ONLY
            index == 0 -> FIRST
            index == count - 1 -> LAST
            else -> MIDDLE
        }
    }
}

/**
 * One slice of [CondensedThreadCard], so each condensed line is its own lazy
 * list row and only the lines on screen are composed. Stacked, the slices
 * draw the same card: rounded top on the first, rounded bottom on the last,
 * 2dp between lines.
 */
@Composable
internal fun CondensedThreadCardRow(segment: CardSegment, content: @Composable ColumnScope.() -> Unit) {
    val isOled = LocalOledMode.current
    val themeColor = LocalNostrVaultColors.current.primary
    val top = segment == CardSegment.ONLY || segment == CardSegment.FIRST
    val bottom = segment == CardSegment.ONLY || segment == CardSegment.LAST
    val corner = 12.dp
    val shape = RoundedCornerShape(
        topStart = if (top) corner else 0.dp,
        topEnd = if (top) corner else 0.dp,
        bottomStart = if (bottom) corner else 0.dp,
        bottomEnd = if (bottom) corner else 0.dp,
    )
    val borderColor = themeColor.copy(alpha = if (isOled) 0.30f else 0.15f)
    val borderWidth = if (isOled) 1.dp else 0.5.dp
    Column(
        modifier = Modifier
            .fillMaxWidth()
            .padding(horizontal = 10.dp)
            .padding(top = if (top) 4.dp else 0.dp, bottom = if (bottom) 4.dp else 0.dp)
            .background(SecondaryGroupedBg, shape)
            .drawBehind {
                // The whole card's outline, run past the open edges and
                // clipped to this slice: no seam lines between lines.
                val stroke = borderWidth.toPx()
                val reach = corner.toPx() * 2
                val y0 = if (top) stroke / 2 else -reach
                val y1 = if (bottom) size.height - stroke / 2 else size.height + reach
                clipRect {
                    drawRoundRect(
                        color = borderColor,
                        topLeft = Offset(stroke / 2, y0),
                        size = Size(size.width - stroke, y1 - y0),
                        cornerRadius = CornerRadius(corner.toPx() - stroke / 2),
                        style = Stroke(width = stroke),
                    )
                }
            }
            .padding(horizontal = 6.dp)
            .padding(top = if (top) 8.dp else 0.dp, bottom = if (bottom) 8.dp else 2.dp),
        content = content,
    )
}

/**
 * One reply in the full thread, as its own lazy list row. Matches iOS
 * ThreadedReplyNode: nested under what it answers with connector lines,
 * a "Show N more replies" pill at [ThreadReplyRows.COLLAPSE_DEPTH], focus
 * highlight. The tree comes from [ThreadReplyRows.build], once per reply list.
 */
@Composable
internal fun ThreadReplyRowItem(
    row: ThreadReplyRow,
    focusedNoteId: String,
    themeColor: androidx.compose.ui.graphics.Color,
    viewModel: NoteDetailViewModel,
    expandedEngagement: Boolean,
    perNoteEngagement: Map<String, EngagementDetails>,
    profiles: Map<String, FeedProfile>,
    /** The screen's quoted-notes cache, read once there rather than per row. */
    quotedNotesCache: Map<String, FeedNote>,
    onProfileClick: (String) -> Unit,
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
    val reply = row.note
    val isFocusedReply = reply.id == focusedNoteId
    val quotedNotesMap = remember(reply.id, reply.quotedEventIds, quotedNotesCache) {
        reply.quotedEventIds.mapNotNull { qid ->
            viewModel.quotedNoteFor(qid)?.let { qid to it }
        }.toMap()
    }
    // Space below, as the nested columns spaced it: none before this
    // reply's own replies, 8dp to a sibling, 12dp between top-level replies.
    val gap = when {
        row.nextDepth > row.depth -> 0.dp
        row.nextDepth <= 1 -> 12.dp
        else -> 8.dp
    }

    Column(
        modifier = modifier
            .drawBehind {
                // One connector per level this reply is nested in, where each
                // level's column of replies drew it (8dp in, 1.5dp wide, 2dp
                // short of the column's ends).
                val inset = 2.dp.toPx()
                val contentBottom = size.height - gap.toPx()
                for (level in 2..row.depth) {
                    val top = if (level == row.depth && row.isFirstChild) inset else 0f
                    val bottom = if (level > row.nextDepth) contentBottom - inset else size.height
                    drawRect(
                        color = themeColor.copy(alpha = 0.25f),
                        topLeft = Offset((16 * (level - 2) + 8).dp.toPx(), top),
                        size = Size(1.5.dp.toPx(), (bottom - top).coerceAtLeast(0f)),
                    )
                }
            }
            .padding(start = (16 * (row.depth - 1)).dp, bottom = gap)
            .animateContentSize(animationSpec = Motion.panel()),
    ) {
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

        // Collapse deep threads — matches iOS "Show X more replies" pill
        val more = row.collapsedReplies
        if (more > 0) {
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
                    text = "Show $more more ${if (more == 1) "reply" else "replies"}",
                    color = themeColor,
                    fontSize = 12.sp,
                    fontWeight = FontWeight.Bold,
                )
            }
        }
    }
}
