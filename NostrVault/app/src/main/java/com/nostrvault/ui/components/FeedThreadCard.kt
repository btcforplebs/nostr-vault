package com.nostrvault.ui.components

import androidx.compose.animation.animateContentSize
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.nostrvault.data.model.FeedNote
import com.nostrvault.data.model.FeedProfile
import com.nostrvault.data.model.FeedThread
import com.nostrvault.data.model.FeedThreadEntry
import com.nostrvault.ui.theme.LocalNostrVaultColors
import com.nostrvault.ui.theme.LocalOledMode
import com.nostrvault.ui.theme.NostrVaultIcons
import com.nostrvault.ui.theme.SecondaryGroupedBg
import com.nostrvault.ui.theme.SecondaryText

/** Three replies is enough to show a conversation is happening without letting one thread own the screen. */
private const val COLLAPSED_REPLY_LIMIT = 3

/**
 * One conversation in the feed: a root note plus its replies, drawn as a
 * single card of condensed lines rather than one card per note.
 *
 * A tap means exactly what it means in the feed's other condensed layout:
 * the first tap opens that line in place into the full note with its action
 * bar, a second tap on the open note goes to the thread. Replying is one tap
 * from the timeline, and the gesture is the same one whichever condensed
 * layout you are in. Mirrors iOS `FeedThreadCard.swift`.
 *
 * @param expandedRow The full note row a tapped line opens into — callers
 *   pass the same `NoteCard(...)` call they already wire for the flat feed,
 *   so this card never needs to know about like/repost/zap/report/etc.
 */
@Composable
fun FeedThreadCard(
    thread: FeedThread,
    profileFor: (String) -> FeedProfile?,
    profiles: Map<String, FeedProfile> = emptyMap(),
    focusedNoteId: String? = null,
    openNoteId: String? = null,
    onOpenNoteChange: (String?) -> Unit = {},
    isExpanded: Boolean = false,
    onExpandedChange: (Boolean) -> Unit = {},
    onProfileClick: (String) -> Unit,
    onOpenThread: (FeedNote) -> Unit,
    onFetchMissingNote: (String) -> Unit = {},
    expandedRow: @Composable (note: FeedNote, depth: Int) -> Unit,
    modifier: Modifier = Modifier,
) {
    val isOled = LocalOledMode.current
    val themeColor = LocalNostrVaultColors.current.primary

    val replies = thread.replies
    val visibleReplies = if (!isExpanded && replies.size > COLLAPSED_REPLY_LIMIT) {
        replies.take(COLLAPSED_REPLY_LIMIT)
    } else {
        replies
    }
    val hiddenReplyCount = replies.size - visibleReplies.size

    LaunchedEffect(thread.rootId, thread.root) {
        // The feed can hold replies whose root it never loaded. Fetch it so
        // the conversation gets its opening line.
        if (thread.root == null) {
            onFetchMissingNote(thread.rootId)
        }
    }

    fun directReplyCount(id: String): Int = thread.entries.count { it.note.parentEventId == id }

    // ThreadCardLine only wires onTap on the condensed branch, which only
    // renders when this note is not the open one — so tapping always opens it;
    // going to the thread happens from the second tap on the *open* row instead
    // (wired into expandedRow's own onNoteClick by the caller).
    fun tapAction(note: FeedNote): () -> Unit = {
        onOpenNoteChange(note.id)
    }

    Column(
        modifier = modifier
            .animateContentSize()
            .background(SecondaryGroupedBg, RoundedCornerShape(12.dp))
            .border(
                width = if (isOled) 1.dp else 0.5.dp,
                color = themeColor.copy(alpha = if (isOled) 0.30f else 0.15f),
                shape = RoundedCornerShape(12.dp),
            )
            .padding(vertical = 8.dp, horizontal = 6.dp),
    ) {
        val root = thread.root
        if (root != null) {
            ThreadCardLine(
                entry = FeedThreadEntry(root, 0),
                replyCount = directReplyCount(root.id),
                profileFor = profileFor,
                profiles = profiles,
                focusedNoteId = focusedNoteId,
                openNoteId = openNoteId,
                onProfileClick = onProfileClick,
                onTap = tapAction(root),
                expandedRow = expandedRow,
            )
        } else {
            MissingRootHeader()
        }

        for (entry in visibleReplies) {
            ThreadCardLine(
                entry = entry,
                replyCount = directReplyCount(entry.note.id),
                profileFor = profileFor,
                profiles = profiles,
                focusedNoteId = focusedNoteId,
                openNoteId = openNoteId,
                onProfileClick = onProfileClick,
                onTap = tapAction(entry.note),
                expandedRow = expandedRow,
            )
        }

        if (hiddenReplyCount > 0) {
            ThreadFoldButton(
                icon = NostrVaultIcons.ChevronDown,
                title = "Show $hiddenReplyCount more ${if (hiddenReplyCount == 1) "reply" else "replies"}",
                themeColor = themeColor,
                onClick = { onExpandedChange(true) },
            )
        } else if (isExpanded && replies.size > COLLAPSED_REPLY_LIMIT) {
            ThreadFoldButton(
                icon = NostrVaultIcons.ChevronDown,
                title = "Show fewer replies",
                themeColor = themeColor,
                onClick = { onExpandedChange(false) },
            )
        }
    }
}

@Composable
private fun ThreadCardLine(
    entry: FeedThreadEntry,
    replyCount: Int,
    profileFor: (String) -> FeedProfile?,
    profiles: Map<String, FeedProfile>,
    focusedNoteId: String?,
    openNoteId: String?,
    onProfileClick: (String) -> Unit,
    onTap: () -> Unit,
    expandedRow: @Composable (note: FeedNote, depth: Int) -> Unit,
) {
    val note = entry.note
    if (openNoteId == note.id) {
        // A line opened in place: the full note, its action bar, and the same
        // rail and indent the condensed line had, so nothing shifts sideways
        // under the tap. Tapping it again goes to the thread (wired by the
        // caller's expandedRow, which reuses onOpenThread as onNoteClick).
        Row(modifier = Modifier.fillMaxWidth()) {
            if (entry.depth > 0) {
                ThreadRail(isOled = LocalOledMode.current, modifier = Modifier.heightIn(min = 1.dp))
            }
            Box(modifier = Modifier.weight(1f).padding(start = condensedIndentWidth(entry.depth))) {
                expandedRow(note, entry.depth)
            }
        }
    } else {
        CondensedNoteLine(
            note = note,
            profile = profileFor(note.pubkey),
            profiles = profiles,
            depth = entry.depth,
            style = CondensedLineStyle.PLAIN,
            isFocused = note.id == focusedNoteId,
            replyCount = replyCount,
            mediaURLs = note.mediaURLs,
            onProfileClick = onProfileClick,
            onTap = onTap,
        )
    }
}

@Composable
private fun MissingRootHeader() {
    Row(
        verticalAlignment = Alignment.CenterVertically,
        modifier = Modifier.padding(horizontal = 8.dp, vertical = 6.dp),
    ) {
        Icon(
            imageVector = NostrVaultIcons.Chat,
            contentDescription = null,
            tint = LocalNostrVaultColors.current.primary.copy(alpha = 0.7f),
            modifier = Modifier.size(12.dp),
        )
        Spacer(Modifier.width(8.dp))
        Text(
            text = "Loading the start of this thread…",
            color = SecondaryText,
            fontSize = 12.sp,
        )
    }
}

@Composable
private fun ThreadFoldButton(
    icon: androidx.compose.ui.graphics.vector.ImageVector,
    title: String,
    themeColor: androidx.compose.ui.graphics.Color,
    onClick: () -> Unit,
) {
    Row(
        verticalAlignment = Alignment.CenterVertically,
        modifier = Modifier
            .padding(start = 22.dp, top = 2.dp)
            .clickable(onClick = onClick)
            .background(themeColor.copy(alpha = 0.1f), RoundedCornerShape(8.dp))
            .padding(vertical = 6.dp, horizontal = 10.dp),
    ) {
        Icon(icon, contentDescription = null, tint = themeColor, modifier = Modifier.size(11.dp))
        Spacer(Modifier.width(6.dp))
        Text(text = title, color = themeColor, fontSize = 12.sp, fontWeight = FontWeight.Bold)
    }
}
