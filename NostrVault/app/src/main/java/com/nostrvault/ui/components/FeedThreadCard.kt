package com.nostrvault.ui.components

import android.os.SystemClock
import androidx.compose.animation.animateContentSize
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.gestures.scrollBy
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyListState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.layout.onGloballyPositioned
import androidx.compose.ui.layout.positionInRoot
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
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.launch
import kotlin.math.abs

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
    /** A line's avatar opens this quick menu, as a full note's does. */
    avatarMenu: AvatarMenuActions? = null,
    onTrustWeb: ((String) -> Unit)? = null,
    onOpenThread: (FeedNote) -> Unit,
    onFetchMissingNote: (String) -> Unit = {},
    /** No relay returned the root after every fetch pass. */
    rootUnavailable: Boolean = false,
    /** Holds a tapped line in place in the feed; null outside the feed. */
    lineAnchor: ThreadLineAnchor? = null,
    /**
     * A bare repost as its line shows it: the note it reposted once that has
     * loaded, otherwise the repost and what to say instead of the text. The
     * feed passes the resolver its condensed rows use; any other note comes
     * back as it is.
     */
    bareRepostDisplay: @Composable (FeedNote) -> Pair<FeedNote, RepostPlaceholder?> = { it to null },
    expandedRow: @Composable (note: FeedNote, depth: Int) -> Unit,
    modifier: Modifier = Modifier,
) {
    val isOled = LocalOledMode.current
    val themeColor = LocalNostrVaultColors.current.primary

    val replies = thread.replies
    val visibleReplies = if (!isExpanded && replies.size > COLLAPSED_REPLY_LIMIT) {
        thread.latestReplies(COLLAPSED_REPLY_LIMIT)
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
        lineAnchor?.lineTapped(note.id)
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
                avatarMenu = avatarMenu,
                onTrustWeb = onTrustWeb,
                onTap = tapAction(root),
                lineAnchor = lineAnchor,
                bareRepostDisplay = bareRepostDisplay,
                expandedRow = expandedRow,
            )
        } else if (!rootUnavailable) {
            // A root no relay has, after every pass, gets no line at all: the
            // replies read as posts, rather than every such card announcing
            // what it can't show.
            MissingRootHeader()
        }

        if (hiddenReplyCount > 0) {
            ThreadFoldButton(
                icon = NostrVaultIcons.ChevronDown,
                title = "Show $hiddenReplyCount earlier ${if (hiddenReplyCount == 1) "reply" else "replies"}",
                themeColor = themeColor,
                onClick = { onExpandedChange(true) },
            )
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
                avatarMenu = avatarMenu,
                onTrustWeb = onTrustWeb,
                onTap = tapAction(entry.note),
                lineAnchor = lineAnchor,
                bareRepostDisplay = bareRepostDisplay,
                expandedRow = expandedRow,
            )
        }

        if (isExpanded && replies.size > COLLAPSED_REPLY_LIMIT) {
            ThreadFoldButton(
                icon = NostrVaultIcons.ChevronDown,
                title = "Show fewer replies",
                themeColor = themeColor,
                onClick = { onExpandedChange(false) },
            )
        }

        // Present only when there is a thread to open: FeedThreadGrouping
        // gives every reply-less note its own one-line thread, which is most
        // of a Global feed, and advertising "Open thread" there points at a
        // conversation that does not exist. The second tap on an open note
        // still reaches the thread screen for any note either way.
        val anchor = root ?: replies.firstOrNull()?.note
        if (anchor != null && replies.isNotEmpty()) {
            OpenThreadRow(onClick = { onOpenThread(anchor) })
        }
    }
}

@Composable
private fun OpenThreadRow(onClick: () -> Unit) {
    Row(
        verticalAlignment = Alignment.CenterVertically,
        modifier = Modifier
            .fillMaxWidth()
            .padding(start = 22.dp, top = 2.dp)
            .clickable(onClick = onClick)
            .padding(vertical = 6.dp, horizontal = 10.dp),
    ) {
        Text(text = "Open thread", color = SecondaryText, fontSize = 12.sp, fontWeight = FontWeight.Bold)
        Spacer(Modifier.weight(1f))
        Icon(
            NostrVaultIcons.Navigate,
            contentDescription = null,
            tint = SecondaryText,
            modifier = Modifier.size(11.dp),
        )
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
    avatarMenu: AvatarMenuActions?,
    onTrustWeb: ((String) -> Unit)?,
    onTap: () -> Unit,
    lineAnchor: ThreadLineAnchor?,
    bareRepostDisplay: @Composable (FeedNote) -> Pair<FeedNote, RepostPlaceholder?>,
    expandedRow: @Composable (note: FeedNote, depth: Int) -> Unit,
) {
    val note = entry.note
    // Where the line's top is, so the feed can hold it there after a tap.
    val anchored = if (lineAnchor != null) {
        Modifier.onGloballyPositioned { lineAnchor.linePositioned(note.id, it.positionInRoot().y) }
    } else {
        Modifier
    }
    if (openNoteId == note.id) {
        // A line opened in place: the full note, its action bar, and the same
        // rail and indent the condensed line had, so nothing shifts sideways
        // under the tap. Tapping it again goes to the thread (wired by the
        // caller's expandedRow, which reuses onOpenThread as onNoteClick).
        Box(
            modifier = anchored
                .fillMaxWidth()
                .padding(start = condensedIndentWidth(entry.depth))
                .then(
                    if (entry.depth > 0) Modifier.threadRail(LocalNostrVaultColors.current.primary, LocalOledMode.current)
                    else Modifier,
                ),
        ) {
            expandedRow(note, entry.depth)
        }
    } else {
        // A bare kind-6 repost carries no text: show the note it reposted,
        // its text, media and time credited to its author, as the condensed
        // feed row does. It keeps the repost's id, so taps are unchanged.
        val (shown, placeholder) = bareRepostDisplay(note)
        CondensedNoteLine(
            note = shown,
            profile = profileFor(shown.pubkey),
            profiles = profiles,
            depth = entry.depth,
            style = CondensedLineStyle.PLAIN,
            isFocused = note.id == focusedNoteId,
            replyCount = replyCount,
            contentOverride = placeholder?.text,
            mediaURLs = shown.mediaURLs,
            onProfileClick = onProfileClick,
            avatarMenu = avatarMenu,
            onTrustWeb = onTrustWeb,
            onTap = onTap,
            modifier = anchored,
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

/**
 * Keeps a tapped thread line where it was tapped. Opening a line closes the
 * one that was open; when that sat above — often a photo — everything below
 * moved up, and the line you tapped could open off screen. The feed records
 * where each line's top is, and for a moment after a tap scrolls by however
 * far the tapped line moves, so it stays put. A line whose top was above the
 * list is brought to its top edge. iOS: ThreadLineTops in FeedThreadCard.swift.
 *
 * The cards animate their height, so the line moves over several frames, not
 * one; the hold follows it for [HOLD_MS] rather than correcting once. Each
 * correction is a [LazyListState.scrollBy] launched from the layout callback,
 * not a scroll inside it, and is measured from the line's latest position
 * when it runs, so corrections never stack. A finger on the list wins.
 */
class ThreadLineAnchor(
    private val scope: CoroutineScope,
    private val listState: LazyListState,
) {
    /** Each line's top, in root coordinates, as last laid out. */
    private val tops = HashMap<String, Float>()

    /** The list's top edge in root coordinates, inside its content padding. */
    var viewportTop: Float = 0f

    private var holdId: String? = null
    private var holdY = 0f
    private var holdUntil = 0L
    private var correcting = false

    internal fun lineTapped(noteId: String) {
        val y = tops[noteId] ?: return
        holdId = noteId
        holdY = maxOf(y, viewportTop)
        holdUntil = SystemClock.uptimeMillis() + HOLD_MS
    }

    internal fun linePositioned(noteId: String, y: Float) {
        if (tops.size > 2_000) tops.clear()
        tops[noteId] = y
        if (noteId != holdId || correcting) return
        if (SystemClock.uptimeMillis() > holdUntil) {
            holdId = null
            return
        }
        if (abs(y - holdY) <= 0.5f) return
        correcting = true
        scope.launch {
            try {
                val top = holdId?.let { tops[it] } ?: return@launch
                listState.scrollBy(top - holdY)
            } finally {
                correcting = false
            }
        }
    }

    private companion object {
        /** Long enough for a card's height animation to settle. */
        const val HOLD_MS = 600L
    }
}
