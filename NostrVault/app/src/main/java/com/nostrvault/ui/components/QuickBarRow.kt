package com.nostrvault.ui.components

import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.nostrvault.data.local.ReactionPick
import com.nostrvault.ui.theme.LocalNostrVaultColors
import com.nostrvault.ui.theme.SecondaryText

/**
 * The picker's top row: the quick bar the reaction button's hold shows.
 * Tap one to react. Edit: tap a slot, then any emoji below to put it there.
 */
@Composable
internal fun QuickBarRow(
    bar: List<ReactionPick>,
    editing: Boolean,
    editSlot: ReactionPick?,
    onToggleEdit: () -> Unit,
    onSlot: (ReactionPick) -> Unit,
) {
    val colors = LocalNostrVaultColors.current
    Column(Modifier.fillMaxWidth()) {
        Row(verticalAlignment = Alignment.CenterVertically, modifier = Modifier.fillMaxWidth()) {
            Text(
                text = when {
                    !editing -> "Quick reactions"
                    editSlot == null -> "Tap the one to change"
                    else -> "Now tap an emoji below"
                },
                color = SecondaryText,
                fontSize = 13.sp,
                modifier = Modifier.weight(1f),
            )
            TextButton(onClick = onToggleEdit) { Text(if (editing) "Done" else "Edit", color = colors.primary) }
        }
        Row(horizontalArrangement = Arrangement.SpaceEvenly, modifier = Modifier.fillMaxWidth()) {
            for (pick in bar) {
                val chosen = editing && editSlot?.key == pick.key
                Box(
                    contentAlignment = Alignment.Center,
                    modifier = Modifier
                        .size(44.dp)
                        .clip(CircleShape)
                        .then(if (chosen) Modifier.background(colors.primary.copy(alpha = 0.3f)) else Modifier)
                        .then(
                            if (editing && !chosen) Modifier.border(1.dp, SecondaryText.copy(alpha = 0.4f), CircleShape)
                            else Modifier,
                        )
                        .semantics { contentDescription = if (editing) "Change ${pick.content}" else pick.content }
                        .clickable { onSlot(pick) }
                        .padding(4.dp),
                ) {
                    ReactionGlyph(pick.content, pick.custom, fontSize = 26.sp)
                }
            }
        }
    }
}
