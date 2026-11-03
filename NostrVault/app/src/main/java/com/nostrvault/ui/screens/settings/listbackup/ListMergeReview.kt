package com.nostrvault.ui.screens.settings.listbackup

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyListScope
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.material3.Checkbox
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.nostrvault.data.model.FeedProfile
import com.nostrvault.service.ListVersionMerge
import com.nostrvault.ui.theme.PrimaryText
import com.nostrvault.ui.theme.SecondaryText
import kotlinx.coroutines.flow.StateFlow

private const val SHOW = 200

/**
 * Review: the merged entries, each with a tick, the confirm card on top. Only
 * behind the confirm card's Review. Ones removed on purpose, and ones that can't be told, come unticked.
 * Web twin: RecoverListPage.jsx MergeView.
 */
@Composable
internal fun ListMergeReview(
    kind: Int,
    name: String,
    rows: List<ListVersionMerge.Row>,
    profiles: StateFlow<Map<String, FeedProfile>>,
    fetch: (List<String>) -> Unit,
    onRows: (List<ListVersionMerge.Row>) -> Unit,
    onBack: () -> Unit,
    confirm: @Composable () -> Unit,
) {
    val known by profiles.collectAsState()
    LaunchedEffect(Unit) { fetch(rows.mapNotNull { ListVersionText.personTag(it.tag) }.filter { it !in known }.take(300)) }
    var showAll by remember { mutableStateOf(emptySet<String>()) }
    val back = rows.filter { it.status != ListVersionMerge.Status.CURRENT }
    val now = rows.filter { it.status == ListVersionMerge.Status.CURRENT }
    val tick: (String) -> Unit = { key -> onRows(rows.map { if (it.key == key) it.copy(ticked = !it.ticked) else it }) }

    fun LazyListScope.section(label: String, list: List<ListVersionMerge.Row>, id: String, note: String) {
        if (list.isEmpty()) return
        item(key = "label-$id") { Text("$label (${list.size})", color = PrimaryText, fontWeight = FontWeight.SemiBold, fontSize = 14.sp) }
        items(if (id in showAll) list else list.take(SHOW), key = { "$id-${it.key}" }) { row ->
            EntryRow(row, known) { tick(row.key) }
        }
        if (list.size > SHOW && id !in showAll) {
            item(key = "all-$id") { TextButton(onClick = { showAll = showAll + id }) { Text("Show all ${list.size}") } }
        }
        item(key = "note-$id") { Text(note, color = SecondaryText, fontSize = 12.sp) }
    }

    ListBackupScaffold(title = "Review $name", onBack = onBack) { padding ->
        LazyColumn(
            contentPadding = PaddingValues(
                top = padding.calculateTopPadding() + 8.dp,
                bottom = padding.calculateBottomPadding() + 16.dp,
                start = 16.dp,
                end = 16.dp,
            ),
            verticalArrangement = Arrangement.spacedBy(6.dp),
            modifier = Modifier.fillMaxSize(),
        ) {
            item(key = "confirm") { confirm() }
            section(ListVersionText.willAdd(kind), back, "back", ListVersionText.BACK_NOTE)
            section(ListVersionText.stillIn(kind), now, "now", if (kind == 3) "Untick someone to unfollow them." else "Untick an entry to take it out.")
        }
    }
}

@Composable
private fun EntryRow(row: ListVersionMerge.Row, known: Map<String, FeedProfile>, onTick: () -> Unit) {
    val label = ListVersionText.entryNote(row)
    ListRow(onClick = onTick) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            Checkbox(checked = row.ticked, onCheckedChange = { onTick() })
            Column(Modifier.weight(1f)) {
                ListEntryLabel(person = ListVersionText.personTag(row.tag), text = entryText(row.tag), known = known, color = PrimaryText, fontSize = 14.sp)
                if (label.isNotEmpty()) Text(label, color = SecondaryText, fontSize = 12.sp)
            }
            if (row.private) {
                Spacer(Modifier.width(6.dp))
                Text("Private", color = Color(0xFFFF9500), fontSize = 12.sp)
            }
        }
    }
}

/** One entry that isn't a person, as text (people show by picture and name, [ListEntryLabel]). */
private fun entryText(tag: List<String>): String {
    val kind = tag.getOrNull(0).orEmpty()
    val v = tag.getOrNull(1).orEmpty()
    return when (kind) {
        "e" -> "Note ${v.take(12)}…"
        "t" -> "#$v"
        "word" -> "“$v”"
        "emoji" -> ":$v:"
        else -> v
    }
}
