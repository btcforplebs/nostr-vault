package com.nostrvault.ui.components

import androidx.compose.foundation.layout.Column
import androidx.compose.runtime.Composable
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.derivedStateOf
import androidx.compose.runtime.getValue
import androidx.compose.runtime.remember
import androidx.compose.ui.Modifier
import com.nostrvault.data.model.FeedNote
import com.nostrvault.data.model.FeedProfile
import kotlinx.coroutines.flow.StateFlow

/**
 * A [CompactNoteCard] with the Popular feed's "🔥 #3 · 1.2k" line above it,
 * as the full layout has (iOS `FeedView.feedNoteRowContent` draws the rank
 * above the row in both layouts). [rankId] is the feed row's own id, which a
 * bare repost's shown [note] does not share. Off Popular the ranks are empty
 * and this is the plain card.
 */
@Composable
fun RankedCompactNoteCard(
    ranks: StateFlow<Map<String, PopularRank>>,
    rankId: String,
    note: FeedNote,
    profile: FeedProfile?,
    profiles: Map<String, FeedProfile> = emptyMap(),
    repostPlaceholder: RepostPlaceholder? = null,
    repostedOriginal: FeedNote? = null,
    engagement: CondensedEngagement = CondensedEngagement.NONE,
    onNoteClick: (String) -> Unit,
    onProfileClick: (String) -> Unit,
    avatarMenu: AvatarMenuActions? = null,
    onTrustWeb: ((String) -> Unit)? = null,
    quotes: List<CondensedQuote> = emptyList(),
    quoteActions: CondensedQuoteActions? = null,
    modifier: Modifier = Modifier,
) {
    // derivedStateOf: a new ranking recomposes only the rows whose rank changed.
    val ranksState = ranks.collectAsState()
    val rank by remember(rankId) { derivedStateOf { ranksState.value[rankId] } }
    Column(modifier) {
        rank?.let { PopularRankLine(it) }
        CompactNoteCard(
            note = note,
            profile = profile,
            profiles = profiles,
            repostPlaceholder = repostPlaceholder,
            repostedOriginal = repostedOriginal,
            engagement = engagement,
            onNoteClick = onNoteClick,
            onProfileClick = onProfileClick,
            avatarMenu = avatarMenu,
            onTrustWeb = onTrustWeb,
            quotes = quotes,
            quoteActions = quoteActions,
        )
    }
}
