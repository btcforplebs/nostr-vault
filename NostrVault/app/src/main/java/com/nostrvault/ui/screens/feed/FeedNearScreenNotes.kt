package com.nostrvault.ui.screens.feed

import androidx.compose.foundation.lazy.LazyListState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.rememberUpdatedState
import androidx.compose.runtime.snapshotFlow
import com.nostrvault.data.model.FeedNote
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.flow.distinctUntilChanged
import kotlinx.coroutines.flow.filterNotNull
import kotlinx.coroutines.flow.map
import kotlinx.coroutines.withContext

/** Rows past the last one on screen whose quotes and parents are asked for early. iOS `FeedPrefetcher.lookahead`. */
internal const val NEAR_SCREEN_ROWS_AHEAD = 8

/**
 * The notes [notes] show inside their own rows: the quotes, the post a reply
 * answers and the original of a bare repost. iOS `FeedPrefetcher.warm`.
 */
internal fun nearScreenReferences(notes: List<FeedNote>): NearScreenReferences {
    val quotes = LinkedHashSet<String>()
    val others = LinkedHashSet<String>()
    for (note in notes) {
        quotes.addAll(note.quotedEventIds)
        note.parentEventId?.let { others.add(it) }
        note.repostedEventId?.takeIf { note.isBareRepost }?.let { others.add(it) }
    }
    return NearScreenReferences(quotes.toList(), others.toList())
}

/** [quotes] are lookup keys (a hex id or an `naddr:` coordinate); [others] are hex ids. */
internal data class NearScreenReferences(val quotes: List<String>, val others: List<String>)

/**
 * Asks first for the quotes and parents of the rows on screen and the next
 * [NEAR_SCREEN_ROWS_AHEAD], so they are there when the row is.
 *
 * [FeedMissingNotesEffects] asks for the same notes for every loaded row,
 * which is close to a thousand ids on a busy feed; without this the row being
 * read waited its turn behind all of them.
 *
 * [notesForRow] returns the notes list row `index` draws, or empty.
 */
@Composable
internal fun FeedNearScreenNotesEffect(
    listState: LazyListState,
    viewModel: FeedViewModel,
    notesForRow: (Int) -> List<FeedNote>,
) {
    val currentNotesForRow by rememberUpdatedState(notesForRow)
    LaunchedEffect(listState) {
        // A scroll frame only compares two row numbers here; the rows are read
        // when those change, or when the screen hands over a new list (a new
        // page, new posts put in above), which changes the lambda.
        snapshotFlow {
            val visible = listState.layoutInfo.visibleItemsInfo
            val first = visible.firstOrNull()?.index ?: return@snapshotFlow null
            Triple(first, visible.last().index, currentNotesForRow)
        }
            .filterNotNull()
            .map { (first, last, rows) -> nearScreenReferences((first..last + NEAR_SCREEN_ROWS_AHEAD).flatMap(rows)) }
            .distinctUntilChanged()
            // Off Main, like the feed-wide ask: the lookup first checks the
            // feed's own index, which is a pass over every loaded note when
            // it has gone stale.
            .collect { refs -> withContext(Dispatchers.Default) { viewModel.fetchNotesNearScreen(refs) } }
    }
}
