package com.nostrvault.ui.components

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import com.nostrvault.ui.theme.*

/** Capsule button / status indicator that backs up the viewed media to the local Blossom store. */
@Composable
internal fun MirrorToBlossomPill(
    state: FeedMediaMirrorViewModel.MirrorState,
    onMirror: () -> Unit,
    modifier: Modifier = Modifier,
) {
    val bg = when (state) {
        FeedMediaMirrorViewModel.MirrorState.Mirrored -> Color(0xFF33CC99).copy(alpha = 0.85f)
        is FeedMediaMirrorViewModel.MirrorState.Failed -> Color(0xFFE53935).copy(alpha = 0.85f)
        else -> Color.Black.copy(alpha = 0.6f)
    }

    // Tapping does nothing while in progress or already mirrored; Idle/Failed trigger a (re)mirror.
    val clickable = state is FeedMediaMirrorViewModel.MirrorState.Idle ||
        state is FeedMediaMirrorViewModel.MirrorState.Failed

    val spoken = when (state) {
        FeedMediaMirrorViewModel.MirrorState.Mirroring -> "Mirroring to Blossom"
        FeedMediaMirrorViewModel.MirrorState.Mirrored -> "Mirrored to Blossom"
        is FeedMediaMirrorViewModel.MirrorState.Failed -> "Mirror failed, retry"
        FeedMediaMirrorViewModel.MirrorState.Idle -> "Mirror to Blossom"
    }

    Row(
        verticalAlignment = Alignment.CenterVertically,
        modifier = modifier
            .clip(CircleShape)
            .background(bg)
            .then(if (clickable) Modifier.clickable(onClick = onMirror) else Modifier)
            .semantics(mergeDescendants = true) { contentDescription = spoken }
            .padding(horizontal = 12.dp, vertical = 8.dp),
    ) {
        when (state) {
            FeedMediaMirrorViewModel.MirrorState.Mirroring -> {
                CircularProgressIndicator(
                    modifier = Modifier.size(16.dp),
                    color = Color.White,
                    strokeWidth = 2.dp,
                )
                Spacer(Modifier.width(6.dp))
                Text("Mirroring…", color = Color.White, fontSize = 12.sp, fontWeight = FontWeight.Bold)
            }
            FeedMediaMirrorViewModel.MirrorState.Mirrored -> {
                Icon(NostrVaultIcons.Check, contentDescription = null, tint = Color.White, modifier = Modifier.size(16.dp))
                Spacer(Modifier.width(6.dp))
                Text("Mirrored", color = Color.White, fontSize = 12.sp, fontWeight = FontWeight.Bold)
            }
            is FeedMediaMirrorViewModel.MirrorState.Failed -> {
                Icon(NostrVaultIcons.Dismiss, contentDescription = null, tint = Color.White, modifier = Modifier.size(16.dp))
                Spacer(Modifier.width(6.dp))
                Text("Retry", color = Color.White, fontSize = 12.sp, fontWeight = FontWeight.Bold)
            }
            FeedMediaMirrorViewModel.MirrorState.Idle -> {
                Icon(NostrVaultIcons.Backup, contentDescription = null, tint = Color.White, modifier = Modifier.size(16.dp))
                Spacer(Modifier.width(6.dp))
                Text("Mirror", color = Color.White, fontSize = 12.sp, fontWeight = FontWeight.Bold)
            }
        }
    }
}
