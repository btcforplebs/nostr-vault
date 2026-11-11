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

/**
 * Capsule button / status indicator that saves the viewed media to the vault on
 * this phone and then to every media server, as the iPhone's Mirror does. The
 * finished state names where the file actually went ([MirrorOutcome]).
 */
@Composable
internal fun MirrorToBlossomPill(
    state: FeedMediaMirrorViewModel.MirrorState,
    onMirror: () -> Unit,
    modifier: Modifier = Modifier,
) {
    val bg = when (state) {
        is FeedMediaMirrorViewModel.MirrorState.Mirrored ->
            if (state.outcome.complete) Color(0xFF33CC99).copy(alpha = 0.85f) else Color(0xFFF59E0B).copy(alpha = 0.85f)
        is FeedMediaMirrorViewModel.MirrorState.Failed -> Color(0xFFE53935).copy(alpha = 0.85f)
        else -> Color.Black.copy(alpha = 0.6f)
    }

    // Tapping does nothing while in progress or once every server has it;
    // Idle/Failed, or a file some servers lack, trigger a (re)mirror.
    val clickable = state is FeedMediaMirrorViewModel.MirrorState.Idle ||
        state is FeedMediaMirrorViewModel.MirrorState.Failed ||
        (state is FeedMediaMirrorViewModel.MirrorState.Mirrored && state.outcome.canRetry)

    val spoken = when (state) {
        FeedMediaMirrorViewModel.MirrorState.Mirroring -> "Saving to your vault and media servers"
        is FeedMediaMirrorViewModel.MirrorState.Mirrored -> state.outcome.spoken
        is FeedMediaMirrorViewModel.MirrorState.Failed -> "Couldn't save to your vault, retry"
        FeedMediaMirrorViewModel.MirrorState.Idle -> "Mirror to your vault and media servers"
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
            is FeedMediaMirrorViewModel.MirrorState.Mirrored -> {
                Icon(
                    if (state.outcome.complete) NostrVaultIcons.Check else NostrVaultIcons.Backup,
                    contentDescription = null, tint = Color.White, modifier = Modifier.size(16.dp),
                )
                Spacer(Modifier.width(6.dp))
                Text(state.outcome.label, color = Color.White, fontSize = 12.sp, fontWeight = FontWeight.Bold)
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
