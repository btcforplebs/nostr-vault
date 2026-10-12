package com.nostrvault.ui.screens.dashboard

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.semantics.clearAndSetSemantics
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.nostrvault.ui.theme.InfoBlue
import com.nostrvault.ui.theme.LocalNostrVaultColors
import com.nostrvault.ui.theme.PrimaryText
import com.nostrvault.ui.theme.SecondaryText
import com.nostrvault.ui.theme.TertiaryGroupedBg

// ═══════════════════════════════════════════════════════════════════
// Storage bar
// ═══════════════════════════════════════════════════════════════════

/** How much room the vault takes, in three parts (iOS VaultContentsSection.storageBar). */
@Composable
internal fun StorageBar(split: VaultDashboardModel.StorageSplit) {
    val colors = LocalNostrVaultColors.current
    val parts = listOf(
        Triple("Notes and data", split.notes, colors.primary),
        Triple("Media", split.media, InfoBlue),
        Triple("Cache", split.cache, SecondaryText),
    )
    val total = maxOf(1L, split.total)
    Column(
        verticalArrangement = Arrangement.spacedBy(12.dp),
        modifier = Modifier
            .fillMaxWidth()
            .clearAndSetSemantics {
                contentDescription = "Storage: " + parts.joinToString(", ") { "${it.first} ${VaultDashboardModel.size(it.second)}" }
            }
            .padding(14.dp),
    ) {
        BoxWithConstraints(
            modifier = Modifier
                .fillMaxWidth()
                .height(10.dp)
                .clip(CircleShape)
                .background(TertiaryGroupedBg),
        ) {
            val width = maxWidth - 4.dp
            Row(horizontalArrangement = Arrangement.spacedBy(2.dp)) {
                parts.filter { it.second > 0 }.forEach { (_, bytes, color) ->
                    val w = maxOf(3.dp, width * (bytes.toFloat() / total.toFloat()))
                    Box(Modifier.width(w).height(10.dp).background(color))
                }
            }
        }
        Row(verticalAlignment = Alignment.Top, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            parts.forEach { (label, bytes, color) ->
                Column(verticalArrangement = Arrangement.spacedBy(2.dp), modifier = Modifier.weight(1f)) {
                    Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(5.dp)) {
                        Box(Modifier.size(7.dp).background(color, CircleShape))
                        Text(label, color = PrimaryText, fontSize = 12.sp, maxLines = 1, overflow = TextOverflow.Ellipsis)
                    }
                    Text(
                        VaultDashboardModel.size(bytes),
                        color = SecondaryText,
                        fontSize = 12.sp,
                        maxLines = 1,
                        modifier = Modifier.padding(start = 12.dp),
                    )
                }
            }
        }
    }
}
