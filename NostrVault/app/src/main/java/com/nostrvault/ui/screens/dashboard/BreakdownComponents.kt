package com.nostrvault.ui.screens.dashboard

import androidx.compose.animation.AnimatedVisibility
import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.animation.expandVertically
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.animation.shrinkVertically
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ColumnScope
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.rotate
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.clearAndSetSemantics
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.semantics.stateDescription
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.nostrvault.ui.theme.NostrVaultIcons
import com.nostrvault.ui.theme.PrimaryText
import com.nostrvault.ui.theme.SecondaryText

fun formatSize(bytes: Long): String {
    if (bytes < 1024) return "$bytes B"
    val kb = bytes / 1024.0
    if (kb < 1024) return "%.1f KB".format(kb)
    val mb = kb / 1024.0
    if (mb < 1024) return "%.1f MB".format(mb)
    val gb = mb / 1024.0
    return "%.2f GB".format(gb)
}

/**
 * A row that opens its breakdown underneath it, one level deep (iOS
 * VaultContentsSection's ExpandingRow). Without [canExpand] it is a plain row
 * and the chevron keeps its room so the numbers still line up.
 */
@Composable
internal fun ExpandingRow(
    icon: ImageVector,
    title: String,
    value: String,
    detail: String?,
    expanded: Boolean,
    canExpand: Boolean,
    onToggle: () -> Unit,
    content: @Composable ColumnScope.() -> Unit,
) {
    val turn by animateFloatAsState(if (expanded && canExpand) 90f else 0f, label = "chevron")
    val spoken = listOfNotNull(value, detail).joinToString(", ")
    Column(Modifier.fillMaxWidth()) {
        Row(
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(12.dp),
            modifier = Modifier
                .fillMaxWidth()
                .then(
                    if (canExpand) {
                        Modifier.clickable(
                            role = Role.Button,
                            onClickLabel = if (expanded) "Hide the breakdown" else "Show the breakdown",
                            onClick = onToggle,
                        )
                    } else {
                        Modifier
                    },
                )
                .semantics(mergeDescendants = true) {
                    contentDescription = "$title, $spoken"
                    if (canExpand) stateDescription = if (expanded) "Expanded" else "Collapsed"
                }
                .padding(horizontal = 14.dp, vertical = 11.dp),
        ) {
            RowIcon(icon, RowState.INFO)
            Column(verticalArrangement = Arrangement.spacedBy(2.dp), modifier = Modifier.weight(1f)) {
                Text(title, color = PrimaryText, fontSize = 15.sp, fontWeight = FontWeight.SemiBold)
                if (detail != null) Text(detail, color = SecondaryText, fontSize = 12.sp)
            }
            Text(value, color = SecondaryText, fontSize = 15.sp, maxLines = 1)
            Icon(
                NostrVaultIcons.Navigate,
                contentDescription = null,
                tint = SecondaryText.copy(alpha = if (canExpand) 0.6f else 0f),
                modifier = Modifier.size(16.dp).rotate(turn),
            )
        }
        AnimatedVisibility(
            visible = expanded && canExpand,
            enter = expandVertically() + fadeIn(),
            exit = shrinkVertically() + fadeOut(),
        ) {
            Column(
                verticalArrangement = Arrangement.spacedBy(6.dp),
                modifier = Modifier.fillMaxWidth().padding(start = 56.dp, end = 14.dp, bottom = 12.dp),
                content = content,
            )
        }
    }
}

/** One line of a breakdown: a name and its number. */
@Composable
internal fun BreakdownLine(title: String, value: String) {
    Row(
        verticalAlignment = Alignment.CenterVertically,
        modifier = Modifier.fillMaxWidth().clearAndSetSemantics { contentDescription = "$title, $value" },
    ) {
        Text(title, color = PrimaryText, fontSize = 13.sp, maxLines = 1, overflow = TextOverflow.Ellipsis, modifier = Modifier.weight(1f))
        Spacer(Modifier.width(8.dp))
        Text(value, color = SecondaryText, fontSize = 13.sp, maxLines = 1)
    }
}
