package com.nostrvault.ui.screens.profile

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.rotate
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.nostrvault.ui.theme.Motion
import com.nostrvault.ui.theme.NostrVaultIcons
import com.nostrvault.ui.theme.SecondaryText
import com.nostrvault.ui.theme.WindowBackground

@Composable
internal fun SectionHeader(section: FollowListSection, collapsible: Boolean, open: Boolean, onToggle: () -> Unit) {
    Row(
        verticalAlignment = Alignment.CenterVertically,
        modifier = Modifier
            .fillMaxWidth()
            // Solid: rows pass under a pinned header, never show through it.
            .background(WindowBackground)
            .heightIn(min = if (collapsible) 48.dp else 32.dp)
            .then(if (collapsible) Modifier.clickable(role = Role.Button, onClick = onToggle) else Modifier)
            .padding(horizontal = 16.dp, vertical = 8.dp),
    ) {
        Text(
            section.group.title.uppercase(),
            color = SecondaryText,
            fontSize = 11.sp,
            fontWeight = FontWeight.SemiBold,
            letterSpacing = 0.6.sp,
        )
        Spacer(Modifier.width(6.dp))
        Text(
            "${section.people.size}",
            color = SecondaryText,
            fontSize = 11.sp,
            fontWeight = FontWeight.Bold,
            fontFamily = FontFamily.Monospace,
        )
        Spacer(Modifier.weight(1f))
        if (collapsible) {
            // chevron.right, 11pt, turning down as the group opens (iOS).
            val turn by animateFloatAsState(if (open) 90f else 0f, Motion.fade(), label = "outside-chevron")
            Icon(
                NostrVaultIcons.Navigate,
                contentDescription = if (open) "Hide this group" else "Show this group",
                tint = SecondaryText,
                modifier = Modifier.size(11.dp).rotate(turn),
            )
        }
    }
}
