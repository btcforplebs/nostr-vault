package com.nostrvault.ui.screens.profile

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.material3.Icon
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.draw.clip
import androidx.compose.ui.unit.dp
import com.nostrvault.ui.theme.NostrVaultIcons
import com.nostrvault.ui.theme.SecondaryText
import com.nostrvault.ui.theme.Surface2

@Composable
internal fun EmptyAvatar() {
    Box(
        contentAlignment = Alignment.Center,
        modifier = Modifier.size(44.dp).clip(CircleShape).background(Surface2),
    ) {
        Icon(NostrVaultIcons.Profile, null, tint = SecondaryText.copy(alpha = 0.6f), modifier = Modifier.size(22.dp))
    }
}
