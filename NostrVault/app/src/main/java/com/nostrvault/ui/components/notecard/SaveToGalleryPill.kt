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

/** Capsule that saves the viewed photo or video to the device gallery. */
@Composable
internal fun SaveToGalleryPill(
    state: FeedMediaMirrorViewModel.SaveState,
    onSave: () -> Unit,
    modifier: Modifier = Modifier,
) {
    val saved = state == FeedMediaMirrorViewModel.SaveState.Saved
    val bg = if (saved) Color(0xFF33CC99).copy(alpha = 0.85f) else Color.Black.copy(alpha = 0.6f)
    Row(
        verticalAlignment = Alignment.CenterVertically,
        modifier = modifier
            .clip(CircleShape)
            .background(bg)
            .then(
                if (state == FeedMediaMirrorViewModel.SaveState.Idle) Modifier.clickable(onClick = onSave)
                else Modifier,
            )
            .semantics(mergeDescendants = true) {
                contentDescription = if (saved) "Saved to gallery" else "Save to gallery"
            }
            .padding(horizontal = 12.dp, vertical = 8.dp),
    ) {
        if (state == FeedMediaMirrorViewModel.SaveState.Saving) {
            CircularProgressIndicator(
                modifier = Modifier.size(16.dp),
                color = Color.White,
                strokeWidth = 2.dp,
            )
        } else {
            Icon(
                imageVector = if (saved) NostrVaultIcons.Check else NostrVaultIcons.Import,
                contentDescription = null,
                tint = Color.White,
                modifier = Modifier.size(16.dp),
            )
        }
        Spacer(Modifier.width(6.dp))
        Text(
            text = when (state) {
                FeedMediaMirrorViewModel.SaveState.Saving -> "Saving…"
                FeedMediaMirrorViewModel.SaveState.Saved -> "Saved"
                FeedMediaMirrorViewModel.SaveState.Idle -> "Save"
            },
            color = Color.White,
            fontSize = 12.sp,
            fontWeight = FontWeight.Bold,
            maxLines = 1,
        )
    }
}
