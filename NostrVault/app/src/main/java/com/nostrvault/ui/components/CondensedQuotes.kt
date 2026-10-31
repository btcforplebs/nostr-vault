package com.nostrvault.ui.components

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.derivedStateOf
import androidx.compose.runtime.getValue
import androidx.compose.runtime.remember
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp
import com.nostrvault.data.model.FeedNote
import com.nostrvault.data.model.FeedProfile
import kotlinx.coroutines.flow.StateFlow

/**
 * One quoted note under a condensed line: the note once it has arrived, null
 * while it is still on its way. Mirrors iOS `CondensedQuote`; the "unavailable"
 * state is the placeholder's own timeout here, as in the full card.
 */
data class CondensedQuote(val id: String, val note: FeedNote?) {
    companion object {
        /**
         * The quotes [note] makes, each as far along as the feed has it. A bare
         * repost passes the note it carries (`withRepostedOriginal`), whose
         * quotes are the ones shown.
         */
        fun resolve(note: FeedNote, find: (String) -> FeedNote?): List<CondensedQuote> =
            note.quotedEventIds.distinct().map { id -> CondensedQuote(id, find(id)) }
    }
}

/**
 * [note]'s quotes, redrawn when one lands. [cache] is only read to subscribe;
 * [find] resolves against the same caches (as the full row's quote lookup does),
 * and derivedStateOf keeps a quote landing for another note from redrawing this one.
 */
@Composable
fun rememberCondensedQuotes(
    note: FeedNote,
    cache: StateFlow<Map<String, FeedNote>>,
    find: (String) -> FeedNote?,
): List<CondensedQuote> {
    if (note.quotedEventIds.isEmpty()) return emptyList()
    val cacheState = cache.collectAsState()
    val quotes by remember(note.id, note.quotedEventIds) {
        derivedStateOf {
            cacheState.value
            CondensedQuote.resolve(note, find)
        }
    }
    return quotes
}

/** Where a condensed line's quotes go when tapped or found missing. */
class CondensedQuoteActions(
    /** Opens the quoted note, as the expanded feed's quote card does. */
    val onOpen: (String) -> Unit,
    val onArticleClick: ((String) -> Unit)? = null,
    /** Asks for a quoted note that hasn't arrived yet. */
    val onMissing: (String) -> Unit = {},
)

/**
 * Each quoted note under a condensed line's text, drawn with the expanded
 * feed's [QuotedNoteCard] so a quote reads the same in every layout, except
 * its photo: the line's own small square, not a full-width picture.
 * iOS: `CondensedNoteLine.quotedNotes`.
 */
@Composable
internal fun CondensedQuotedNotes(
    quotes: List<CondensedQuote>,
    profiles: Map<String, FeedProfile>,
    actions: CondensedQuoteActions,
    modifier: Modifier = Modifier,
) {
    Column(modifier.fillMaxWidth(), verticalArrangement = Arrangement.spacedBy(4.dp)) {
        for (quote in quotes) {
            val quoted = quote.note
            if (quoted != null) {
                QuotedNoteCard(
                    note = quoted,
                    profile = profiles[quoted.pubkey],
                    profiles = profiles,
                    onClick = actions.onOpen,
                    onArticleClick = actions.onArticleClick,
                    condensedMedia = true,
                )
            } else {
                LaunchedEffect(quote.id) { actions.onMissing(quote.id) }
                QuotedNotePlaceholder(identifier = quote.id, onClick = actions.onOpen)
            }
        }
    }
}
