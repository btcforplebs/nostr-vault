package com.nostrvault.ui.screens.emoji

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.nostrvault.service.emoji.OwnEmojiSets
import com.nostrvault.ui.components.CustomEmojiImage
import com.nostrvault.ui.theme.PrimaryText
import com.nostrvault.ui.theme.SecondaryText
import java.text.DateFormat
import java.util.Date

/**
 * Your old sets, at the top of Find emoji sets (Logen 2026-11-13): your own sets found on your relays, in the vault
 * and in its list history that aren't in your emoji list, or whose newest copy lost its emoji. Add back is the only
 * thing that signs. Apple twin: the same part in `EmojiSetsBrowseSheet.swift` (Tal's next).
 */
@Composable
fun EmojiOldSetsSection(state: EmojiVaultViewModel.OldSetsState, onAddBack: (OwnEmojiSets.OldSet) -> Unit) {
    val sets = state.found?.sets.orEmpty()
    if (!state.loading && sets.isEmpty()) return
    Column(Modifier.fillMaxWidth().padding(top = 8.dp)) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            Text("Your old sets", color = PrimaryText, fontWeight = FontWeight.SemiBold, fontSize = 16.sp, modifier = Modifier.weight(1f))
            if (state.loading) CircularProgressIndicator(Modifier.size(16.dp), strokeWidth = 2.dp)
        }
        if (state.found?.vaultRead == false) {
            Text("Your vault isn't running, so only your relays were read.", color = SecondaryText, fontSize = 12.sp)
        }
        sets.forEach { old -> OldSetRow(old, busy = state.busy == old.address, enabled = state.busy == null, onAddBack) }
        HorizontalDivider(Modifier.padding(top = 8.dp))
    }
}

@Composable
private fun OldSetRow(old: OwnEmojiSets.OldSet, busy: Boolean, enabled: Boolean, onAddBack: (OwnEmojiSets.OldSet) -> Unit) {
    Column(Modifier.fillMaxWidth().padding(vertical = 10.dp)) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            Column(Modifier.weight(1f)) {
                Text(old.set.title, color = PrimaryText, fontWeight = FontWeight.SemiBold, maxLines = 1)
                Text(why(old), color = SecondaryText, fontSize = 12.sp)
            }
            if (busy) {
                CircularProgressIndicator(Modifier.size(20.dp), strokeWidth = 2.dp)
            } else {
                TextButton(onClick = { onAddBack(old) }, enabled = enabled) { Text("Add back") }
            }
        }
        Row(horizontalArrangement = Arrangement.spacedBy(4.dp)) {
            old.set.emojis.take(PREVIEW).forEach { CustomEmojiImage(it, size = 28.dp) }
            if (old.set.emojis.size > PREVIEW) {
                Spacer(Modifier.size(4.dp))
                Text("+${old.set.emojis.size - PREVIEW}", color = SecondaryText, fontSize = 12.sp)
            }
        }
    }
}

/** One line on what Add back will do. */
private fun why(old: OwnEmojiSets.OldSet): String {
    val count = if (old.set.emojis.size == 1) "1 emoji" else "${old.set.emojis.size} emoji"
    val date = DateFormat.getDateInstance(DateFormat.MEDIUM).format(Date(old.version.createdAt * 1000))
    return if (old.restore) {
        val now = if (old.newestCount == 0) "now empty" else "now ${old.newestCount}"
        "$count on $date · $now"
    } else {
        "$count · not in your emoji list"
    }
}

private const val PREVIEW = 8
