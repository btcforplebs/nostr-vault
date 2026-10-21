package com.nostrvault.ui.screens

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.nostrvault.data.model.*
import com.nostrvault.ui.components.*
import com.nostrvault.ui.theme.*
import kotlinx.coroutines.flow.*
import java.util.*

/**
 * One tappable pill in an engagement row: the hero note's, or with [compact]
 * the smaller one under each note in the thread (iOS ThreadNoteEngagementRow:
 * 6x3 padding, 6pt corners, white at 0.04).
 */
@Composable
internal fun EngagementPill(
    description: String,
    onClick: () -> Unit,
    compact: Boolean = false,
    content: @Composable RowScope.() -> Unit,
) {
    Row(
        verticalAlignment = Alignment.CenterVertically,
        modifier = Modifier
            .clip(RoundedCornerShape(if (compact) 6.dp else 8.dp))
            .background(androidx.compose.ui.graphics.Color.White.copy(alpha = if (compact) 0.04f else 0.05f))
            .clickable(onClick = onClick)
            .semantics(mergeDescendants = true) { contentDescription = description }
            .padding(horizontal = if (compact) 6.dp else 8.dp, vertical = if (compact) 3.dp else 5.dp),
        content = content,
    )
}

/** Which engagement list a pill opens. */
internal enum class EngagementSheetKind { REACTIONS, ZAPS, REPOSTS }

/** An open engagement sheet: which list, and for which note (null: the focused one). */
internal data class EngagementSheetTarget(val kind: EngagementSheetKind, val noteId: String?)

/**
 * Under a parent or reply in the thread when thread stats are on: a hairline,
 * then emoji pills (three, then "+N"), zap sats and reposts, each pill opening
 * its list. iOS ThreadNoteEngagementRow. Draws nothing for a note with none.
 */
@Composable
internal fun ThreadNoteEngagementRow(
    details: EngagementDetails,
    onClick: (EngagementSheetKind) -> Unit,
    modifier: Modifier = Modifier,
) {
    val zapsOnly = LocalZapsOnlyMode.current
    val row = remember(details, zapsOnly) { EngagementSummary.threadRow(details, zapsOnly) }
    if (row.isEmpty) return
    Column(modifier = modifier.padding(horizontal = 12.dp)) {
        HorizontalDivider(
            color = SecondaryText.copy(alpha = 0.1f),
            thickness = 0.5.dp,
            modifier = Modifier.padding(top = 8.dp),
        )
        Row(
            horizontalArrangement = Arrangement.spacedBy(8.dp),
            verticalAlignment = Alignment.CenterVertically,
            modifier = Modifier.padding(top = 4.dp, bottom = 8.dp),
        ) {
            if (row.emojiGroups.isNotEmpty()) {
                val shown = row.emojiGroups.take(EngagementSummary.THREAD_ROW_EMOJI_GROUPS)
                EngagementPill(
                    description = row.emojiGroups.joinToString(prefix = "Reactions: ") { "${it.emoji} ${it.count}" },
                    onClick = { onClick(EngagementSheetKind.REACTIONS) },
                    compact = true,
                ) {
                    shown.forEachIndexed { index, group ->
                        if (index > 0) Spacer(Modifier.width(3.dp))
                        Text(group.emoji, fontSize = 11.sp)
                        Spacer(Modifier.width(1.dp))
                        Text("${group.count}", color = SecondaryText, fontSize = 9.sp, fontWeight = FontWeight.Bold, fontFamily = FontFamily.Monospace)
                    }
                    if (row.emojiGroups.size > shown.size) {
                        Spacer(Modifier.width(3.dp))
                        Text("+${row.emojiGroups.size - shown.size}", color = SecondaryText, fontSize = 9.sp, fontWeight = FontWeight.Bold, fontFamily = FontFamily.Monospace)
                    }
                }
            }
            if (row.zapCount > 0) {
                val sats = EngagementSummary.satsText(row.zapSats)
                EngagementPill(
                    description = "Zaps: ${row.zapCount}, $sats sats",
                    onClick = { onClick(EngagementSheetKind.ZAPS) },
                    compact = true,
                ) {
                    Icon(NostrVaultIcons.Zap, contentDescription = null, tint = ZapOrange, modifier = Modifier.size(9.dp))
                    Spacer(Modifier.width(2.dp))
                    Text(sats, color = SecondaryText, fontSize = 9.sp, fontWeight = FontWeight.SemiBold, fontFamily = FontFamily.Monospace)
                }
            }
            if (row.reposts > 0) {
                EngagementPill(
                    description = "Reposts: ${row.reposts}",
                    onClick = { onClick(EngagementSheetKind.REPOSTS) },
                    compact = true,
                ) {
                    Icon(NostrVaultIcons.Repost, contentDescription = null, tint = RepostGreen, modifier = Modifier.size(9.dp))
                    Spacer(Modifier.width(2.dp))
                    Text("${row.reposts}", color = SecondaryText, fontSize = 9.sp, fontWeight = FontWeight.SemiBold, fontFamily = FontFamily.Monospace)
                }
            }
        }
    }
}
