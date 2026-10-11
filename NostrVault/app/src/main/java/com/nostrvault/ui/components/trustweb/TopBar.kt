package com.nostrvault.ui.components

import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.nostrvault.ui.theme.LocalNostrVaultColors
import com.nostrvault.ui.theme.NostrVaultIcons
import com.nostrvault.ui.theme.PrimaryText

// ── Small pieces ─────────────────────────────────────────────────────

@Composable
internal fun TopBar(
    title: String,
    onDone: (() -> Unit)?,
    onList: (() -> Unit)?,
) {
    val accent = LocalNostrVaultColors.current.primary
    Box(Modifier.fillMaxWidth().height(48.dp).padding(horizontal = 8.dp)) {
        if (onDone != null) {
            TextButton(onClick = onDone, modifier = Modifier.align(Alignment.CenterStart)) {
                Text("Done", color = accent, fontSize = 16.sp)
            }
        }
        Text(
            title,
            color = PrimaryText,
            fontSize = 17.sp,
            fontWeight = FontWeight.SemiBold,
            maxLines = 1,
            overflow = TextOverflow.Ellipsis,
            textAlign = TextAlign.Center,
            modifier = Modifier.align(Alignment.Center).padding(horizontal = 72.dp),
        )
        Row(Modifier.align(Alignment.CenterEnd)) {
            if (onList != null) {
                IconButton(onClick = onList) {
                    Icon(NostrVaultIcons.PeopleList, contentDescription = "People on this globe", tint = accent)
                }
            }
        }
    }
}
