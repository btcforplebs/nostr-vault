package com.nostrvault.ui.screens

import androidx.compose.animation.AnimatedVisibility
import androidx.compose.animation.expandHorizontally
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.animation.shrinkHorizontally
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.semantics.stateDescription
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.nostrvault.ui.theme.LocalNostrVaultColors
import com.nostrvault.ui.theme.NostrVaultIcons
import com.nostrvault.ui.theme.SecondaryText

/**
 * The note screen's Thread Stats switch: reactions, zaps and reposts under
 * every note in the thread. Off, a bare chart icon; on, a tinted capsule
 * that says "Stats", so it's clear what is on.
 */
@Composable
internal fun ThreadStatsToggle(isOn: Boolean, onClick: () -> Unit) {
    val accent = LocalNostrVaultColors.current.primary
    Row(
        verticalAlignment = Alignment.CenterVertically,
        modifier = Modifier
            .height(40.dp)
            .widthIn(min = 40.dp)
            .clip(CircleShape)
            .background(if (isOn) accent.copy(alpha = 0.18f) else Color.Transparent)
            .clickable(role = Role.Switch, onClick = onClick)
            .semantics {
                contentDescription = "Thread Stats"
                stateDescription = if (isOn) "On" else "Off"
            }
            .padding(horizontal = 7.5.dp),
    ) {
        Icon(
            NostrVaultIcons.BarChart,
            contentDescription = null,
            tint = if (isOn) accent else SecondaryText,
            modifier = Modifier.size(25.dp),
        )
        AnimatedVisibility(
            visible = isOn,
            enter = fadeIn() + expandHorizontally(),
            exit = fadeOut() + shrinkHorizontally(),
        ) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Spacer(Modifier.width(4.dp))
                Text("Stats", color = accent, fontSize = 13.sp, fontWeight = FontWeight.SemiBold)
                Spacer(Modifier.width(2.dp))
            }
        }
    }
}
