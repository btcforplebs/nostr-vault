package com.nostrvault.ui.components

import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import com.nostrvault.data.model.ArticleMeta
import com.nostrvault.data.model.FeedNote
import com.nostrvault.data.model.FeedProfile
import com.nostrvault.data.model.condensedTitle

/**
 * Compact View's feed row. It draws through the shared [CondensedNoteLine] so
 * the feed, a thread's ancestors and its replies cannot drift apart, as on iOS
 * (`FeedNoteRow.compactLayout`). Tap expands it in place.
 *
 * A bare repost arrives already resolved to its original ([note] credited to
 * the original's author, `repostedBy` set), so the avatar and the name are the
 * same person and the green repost marker says it was passed on.
 */
@Composable
fun CompactNoteCard(
    note: FeedNote,
    profile: FeedProfile?,
    profiles: Map<String, FeedProfile> = emptyMap(),
    /** A bare repost still waiting for its original, or without one. See [NoteCard]. */
    repostPlaceholder: RepostPlaceholder? = null,
    /**
     * The original behind a resolved bare repost. [note] keeps kind 6, so the
     * original's kind is what makes the line an article title or a poll question.
     */
    repostedOriginal: FeedNote? = null,
    engagement: CondensedEngagement = CondensedEngagement.NONE,
    onNoteClick: (String) -> Unit,
    onProfileClick: (String) -> Unit,
    modifier: Modifier = Modifier,
) {
    val isArticle = (repostedOriginal ?: note).kind == ArticleMeta.KIND
    CondensedNoteLine(
        note = note,
        profile = profile,
        profiles = profiles,
        style = CondensedLineStyle.CARD,
        contentOverride = repostPlaceholder?.text
            ?: repostedOriginal?.let { it.condensedTitle ?: it.content },
        mediaURLs = note.mediaURLs,
        engagement = engagement,
        // An article's line is its title; there is nothing there to translate.
        showsTranslate = !isArticle && repostPlaceholder == null,
        onProfileClick = onProfileClick,
        onTap = { onNoteClick(note.id) },
        modifier = modifier.fillMaxWidth(),
    )
}
