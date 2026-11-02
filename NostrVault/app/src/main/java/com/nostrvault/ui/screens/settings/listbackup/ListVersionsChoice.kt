package com.nostrvault.ui.screens.settings.listbackup

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.nostrvault.ui.theme.PrimaryText
import com.nostrvault.ui.theme.SecondaryText

/**
 * The top of a list's versions page: what Restore does, and Merge as its own explained entry (Logen 2026-11-02:
 * not a bare button). [onMerge] null: this list can't be merged, so only Restore is said.
 */
@Composable
internal fun ListVersionsChoice(kind: Int, onMerge: (() -> Unit)?) = Column(verticalArrangement = Arrangement.spacedBy(4.dp)) {
    Text("Bring back an old version", color = PrimaryText, fontSize = 15.sp, fontWeight = FontWeight.SemiBold)
    Text(ListVersionText.RESTORE_LINE, color = SecondaryText, fontSize = 13.sp)
    if (onMerge == null) return@Column
    ListRow(onClick = onMerge) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            Column(Modifier.weight(1f)) {
                Text("Merge old versions", color = Color(0xFF0A84FF), fontSize = 15.sp, fontWeight = FontWeight.SemiBold)
                Text(ListVersionText.mergeBlurb(kind), color = SecondaryText, fontSize = 13.sp)
            }
            Text("›", color = SecondaryText, fontSize = 22.sp)
        }
    }
}
