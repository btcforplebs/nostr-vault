package com.nostrvault.ui.screens.dashboard

import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.offset
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.CheckCircle
import androidx.compose.material.icons.filled.Error
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.LinearProgressIndicator
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.heading
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.semantics.stateDescription
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.nostrvault.ui.theme.CardBorder
import com.nostrvault.ui.theme.LocalNostrVaultColors
import com.nostrvault.ui.theme.NostrVaultIcons
import com.nostrvault.ui.theme.PrimaryText
import com.nostrvault.ui.theme.SecondaryGroupedBg
import com.nostrvault.ui.theme.SecondaryText
import com.nostrvault.ui.theme.SuccessGreen
import com.nostrvault.ui.theme.TertiaryGroupedBg
import com.nostrvault.ui.theme.ZapOrange

// ═══════════════════════════════════════════════════════════════════
// Building blocks
// ═══════════════════════════════════════════════════════════════════

/** A titled card of rows: the section style every Vault Dashboard block uses. */
@Composable
internal fun DashSection(
    title: String,
    detail: String? = null,
    /** Off for content that draws its own cards, like the tiles. */
    framed: Boolean = true,
    content: @Composable () -> Unit,
) {
    Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
        Row(
            verticalAlignment = Alignment.CenterVertically,
            modifier = Modifier.fillMaxWidth().padding(horizontal = 4.dp).semantics(mergeDescendants = true) { heading() },
        ) {
            Text(title, color = SecondaryText, fontSize = 13.sp, fontWeight = FontWeight.SemiBold, modifier = Modifier.weight(1f))
            if (detail != null) {
                Text(detail, color = SecondaryText, fontSize = 13.sp, fontWeight = FontWeight.Medium)
            }
        }
        if (framed) {
            Column(
                modifier = Modifier
                    .fillMaxWidth()
                    .clip(RoundedCornerShape(12.dp))
                    .background(SecondaryGroupedBg)
                    .border(1.dp, CardBorder, RoundedCornerShape(12.dp)),
            ) { content() }
        } else {
            content()
        }
    }
}

@Composable
internal fun DashDivider() {
    HorizontalDivider(color = CardBorder, modifier = Modifier.padding(start = 52.dp))
}

internal enum class RowState { DONE, TODO, INFO }

@Composable
private fun RowState.color(): Color = when (this) {
    RowState.DONE -> SuccessGreen
    RowState.TODO -> ZapOrange
    RowState.INFO -> LocalNostrVaultColors.current.primary
}

private fun RowState.spoken(): String = when (this) {
    RowState.DONE -> "Done"
    RowState.TODO -> "Needs attention"
    RowState.INFO -> ""
}

@Composable
internal fun RowIcon(icon: ImageVector, state: RowState) {
    val tint = state.color()
    Box(modifier = Modifier.size(30.dp)) {
        Box(
            contentAlignment = Alignment.Center,
            modifier = Modifier.size(30.dp).background(tint.copy(alpha = 0.14f), RoundedCornerShape(8.dp)),
        ) {
            Icon(icon, contentDescription = null, tint = tint, modifier = Modifier.size(16.dp))
        }
        if (state != RowState.INFO) {
            Box(
                contentAlignment = Alignment.Center,
                modifier = Modifier
                    .align(Alignment.BottomEnd)
                    .offset(x = 4.dp, y = 4.dp)
                    .size(13.dp)
                    .background(Color.White, CircleShape),
            ) {
                Icon(
                    if (state == RowState.DONE) Icons.Filled.CheckCircle else Icons.Filled.Error,
                    contentDescription = null,
                    tint = tint,
                    modifier = Modifier.size(13.dp),
                )
            }
        }
    }
}

@Composable
private fun RowText(title: String, detail: String, modifier: Modifier = Modifier) {
    Column(verticalArrangement = Arrangement.spacedBy(2.dp), modifier = modifier) {
        Text(title, color = PrimaryText, fontSize = 15.sp, fontWeight = FontWeight.SemiBold)
        Text(detail, color = SecondaryText, fontSize = 12.sp)
    }
}

/** A row with a trailing control (a button) and an optional progress bar. */
@Composable
internal fun DashRow(
    icon: ImageVector,
    title: String,
    detail: String,
    state: RowState,
    progress: Float? = null,
    trailing: @Composable () -> Unit,
) {
    Column(
        verticalArrangement = Arrangement.spacedBy(8.dp),
        modifier = Modifier.fillMaxWidth().padding(horizontal = 14.dp, vertical = 11.dp),
    ) {
        Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(12.dp)) {
            RowIcon(icon, state)
            RowText(
                title,
                detail,
                Modifier.weight(1f).semantics(mergeDescendants = true) { stateDescription = state.spoken() },
            )
            trailing()
        }
        if (progress != null) {
            LinearProgressIndicator(
                progress = { progress.coerceIn(0f, 1f) },
                color = LocalNostrVaultColors.current.primary,
                trackColor = TertiaryGroupedBg,
                modifier = Modifier.fillMaxWidth().padding(start = 42.dp),
            )
        }
    }
}

/** A row that opens a settings page. */
@Composable
internal fun DashRowLink(
    icon: ImageVector,
    title: String,
    detail: String,
    state: RowState,
    onClick: () -> Unit,
) {
    Row(
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(12.dp),
        modifier = Modifier
            .fillMaxWidth()
            .clickable(role = Role.Button, onClick = onClick)
            .semantics(mergeDescendants = true) { stateDescription = state.spoken() }
            .padding(horizontal = 14.dp, vertical = 11.dp),
    ) {
        RowIcon(icon, state)
        RowText(title, detail, Modifier.weight(1f))
        if (state == RowState.TODO) {
            Text("Fix", color = ZapOrange, fontSize = 13.sp, fontWeight = FontWeight.SemiBold)
        }
        Icon(NostrVaultIcons.Navigate, contentDescription = null, tint = SecondaryText.copy(alpha = 0.6f), modifier = Modifier.size(16.dp))
    }
}

@Composable
internal fun RowLabel(icon: ImageVector, title: String, modifier: Modifier = Modifier) {
    val primary = LocalNostrVaultColors.current.primary
    Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(12.dp), modifier = modifier) {
        Box(
            contentAlignment = Alignment.Center,
            modifier = Modifier.size(30.dp).background(primary.copy(alpha = 0.14f), RoundedCornerShape(8.dp)),
        ) {
            Icon(icon, contentDescription = null, tint = primary, modifier = Modifier.size(16.dp))
        }
        Text(title, color = PrimaryText, fontSize = 15.sp, fontWeight = FontWeight.Medium)
    }
}

/** A quick link to one of the vault's own settings, showing its current value. */
@Composable
internal fun SettingLink(icon: ImageVector, title: String, value: String?, onClick: () -> Unit) {
    Row(
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(8.dp),
        modifier = Modifier
            .fillMaxWidth()
            .heightIn(min = 48.dp)
            .clickable(role = Role.Button, onClick = onClick)
            .padding(horizontal = 14.dp, vertical = 8.dp),
    ) {
        RowLabel(icon, title, Modifier.weight(1f))
        if (value != null) {
            Text(value, color = SecondaryText, fontSize = 15.sp)
        }
        Icon(NostrVaultIcons.Navigate, contentDescription = null, tint = SecondaryText.copy(alpha = 0.6f), modifier = Modifier.size(16.dp))
    }
}

@Composable
internal fun RowButton(title: String, isLoading: Boolean = false, enabled: Boolean = true, onClick: () -> Unit) {
    val primary = LocalNostrVaultColors.current.primary
    Surface(
        onClick = onClick,
        enabled = enabled && !isLoading,
        shape = CircleShape,
        color = primary.copy(alpha = 0.12f),
        modifier = Modifier.heightIn(min = 30.dp),
    ) {
        Box(contentAlignment = Alignment.Center, modifier = Modifier.heightIn(min = 30.dp).padding(horizontal = 12.dp)) {
            if (isLoading) {
                CircularProgressIndicator(color = primary, strokeWidth = 2.dp, modifier = Modifier.size(14.dp))
            } else {
                Text(
                    title,
                    color = primary.copy(alpha = if (enabled) 1f else 0.4f),
                    fontSize = 13.sp,
                    fontWeight = FontWeight.SemiBold,
                )
            }
        }
    }
}
