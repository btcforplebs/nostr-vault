package com.nostrvault.ui.navigation

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.material3.VerticalDivider
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.key
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.core.os.bundleOf
import androidx.hilt.lifecycle.viewmodel.compose.hiltViewModel
import androidx.navigation.NavHostController
import com.nostrvault.ui.components.PaneViewModelScope
import com.nostrvault.ui.screens.ArticleReaderScreen
import com.nostrvault.ui.screens.NoteDetailScreen
import com.nostrvault.ui.theme.NostrVaultIcons
import com.nostrvault.ui.theme.PrimaryText
import com.nostrvault.ui.theme.SecondaryText
import com.nostrvault.ui.theme.SeparatorColor
import com.nostrvault.ui.theme.WindowBackground

/** iOS NoteSplitMetrics. */
internal object NoteSplitMetrics {
    val defaultList = 380.dp
    /** Floors, not preferences: below these a column stops being usable. */
    val minList = 280.dp
    val minDetail = 360.dp
    /** Narrower than this the pane shows one column and a note opens over it, as on a phone. */
    val minSplit = minList + minDetail + 1.dp
}

/**
 * Width of the list column when [width] has room for a note beside it, else
 * null (one column). The list keeps its default width and gives way only as
 * far as the note column's floor.
 */
internal fun noteSplitListWidth(width: Dp): Dp? =
    if (width < NoteSplitMetrics.minSplit) null
    else minOf(NoteSplitMetrics.defaultList, width - NoteSplitMetrics.minDetail)

/** What the right-hand pane shows: a note's thread, or a long-form post in the reader. */
internal sealed interface NotePick {
    val id: String
    data class Note(override val id: String) : NotePick
    data class Article(override val id: String) : NotePick

    companion object {
        /** For rememberSaveable: "n:<id>" / "a:<id>". */
        fun encode(pick: NotePick?): String? = when (pick) {
            is Note -> "n:${pick.id}"
            is Article -> "a:${pick.id}"
            null -> null
        }

        fun decode(raw: String?): NotePick? = when {
            raw == null || raw.length < 3 -> null
            raw.startsWith("n:") -> Note(raw.substring(2))
            raw.startsWith("a:") -> Article(raw.substring(2))
            else -> null
        }
    }
}

/** How a list screen opens a note: into the pane beside it, or pushed like on a phone. */
internal class NoteOpeners(val note: (String) -> Unit, val article: (String) -> Unit)

/**
 * Tablet two-pane layout for the note lists (iOS NoteSplitPane): the scrolling
 * list on the left and the picked note held open on the right, so both the
 * list and the thread are on screen. On a phone, or a pane too narrow for two
 * columns, [content] gets openers that push the route as before.
 *
 * Reading a note in the right pane keeps replies to the same pane; profiles,
 * the composer and the like go full screen through [navController].
 */
@Composable
internal fun NoteSplitPane(
    navController: NavHostController,
    emptyMessage: String,
    content: @Composable (NoteOpeners) -> Unit,
) {
    var raw by rememberSaveable { mutableStateOf<String?>(null) }
    val pick = NotePick.decode(raw)
    BoxWithConstraints(Modifier.fillMaxSize()) {
        val listWidth = noteSplitListWidth(maxWidth)
        if (listWidth == null) {
            content(
                NoteOpeners(
                    note = { navController.navigate(Screen.NoteDetail.createRoute(it)) },
                    article = { navController.navigate(Screen.ArticleReader.createRoute(it)) },
                ),
            )
        } else {
            Row(Modifier.fillMaxSize().background(WindowBackground)) {
                Box(Modifier.width(listWidth).fillMaxHeight()) {
                    content(
                        NoteOpeners(
                            note = { raw = NotePick.encode(NotePick.Note(it)) },
                            article = { raw = NotePick.encode(NotePick.Article(it)) },
                        ),
                    )
                }
                VerticalDivider(color = SeparatorColor)
                Box(Modifier.weight(1f).fillMaxHeight()) {
                    if (pick != null) {
                        key(pick) { NoteDetailPane(pick, navController, onPick = { raw = NotePick.encode(it) }) }
                    } else {
                        NoNoteSelected(emptyMessage)
                    }
                }
            }
        }
    }
}

@Composable
private fun NoteDetailPane(pick: NotePick, navController: NavHostController, onPick: (NotePick?) -> Unit) {
    val profile: (String) -> Unit = { navController.navigate(Screen.Profile.createRoute(it)) }
    val reply: (String) -> Unit = { navController.navigate(Screen.ComposeNote.createRoute(replyToNoteId = it)) }
    val quote: (String) -> Unit = { navController.navigate(Screen.ComposeNote.createRoute(quoteToNoteId = it)) }
    PaneViewModelScope(pick, bundleOf("noteId" to pick.id)) {
        when (pick) {
            is NotePick.Note -> NoteDetailScreen(
                noteId = pick.id,
                onProfileClick = profile,
                onNoteClick = { onPick(NotePick.Note(it)) },
                onArticleClick = { onPick(NotePick.Article(it)) },
                onReply = reply,
                onQuote = quote,
                onBack = { onPick(null) },
                viewModel = hiltViewModel(key = "note-pane:${pick.id}"),
            )
            is NotePick.Article -> ArticleReaderScreen(
                onBack = { onPick(null) },
                onProfileClick = profile,
                onComment = reply,
                onNoteClick = { onPick(NotePick.Note(it)) },
                viewModel = hiltViewModel(key = "article-pane:${pick.id}"),
            )
        }
    }
}

/** iOS ContentUnavailableView in the right pane before a note is picked. */
@Composable
private fun NoNoteSelected(message: String) {
    Column(
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.spacedBy(8.dp, Alignment.CenterVertically),
        modifier = Modifier
            .fillMaxSize()
            .padding(horizontal = 24.dp)
            .semantics(mergeDescendants = true) {},
    ) {
        Icon(
            imageVector = NostrVaultIcons.DMs,
            contentDescription = null,
            tint = SecondaryText,
            modifier = Modifier.size(44.dp).padding(bottom = 4.dp),
        )
        Text("No Note Selected", color = PrimaryText, fontSize = 20.sp, fontWeight = FontWeight.Bold, textAlign = TextAlign.Center)
        Text(message, color = SecondaryText, fontSize = 15.sp, textAlign = TextAlign.Center)
    }
}
