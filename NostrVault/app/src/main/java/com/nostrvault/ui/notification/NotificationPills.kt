package com.nostrvault.ui.notification

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.shadow
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.nostrvault.ui.theme.ErrorRed
import com.nostrvault.ui.theme.LocalNostrVaultColors
import com.nostrvault.ui.theme.NostrVaultIcons
import com.nostrvault.ui.theme.SuccessGreen
import com.nostrvault.ui.theme.ZapOrange

/**
 * Individual notification pill composables matching the iOS Capsule-based
 * notification banners. Each renders a solid-color pill with icon + text.
 */

private val PillShape = RoundedCornerShape(50)

// ── Zap ──────────────────────────────────────────────────────────

@Composable
fun ZapPill(notification: ZapNotification) {
    val bgColor = when (notification.status) {
        ZapStatus.SENDING -> ZapOrange
        ZapStatus.SUCCESS -> SuccessGreen
        is ZapStatus.FAILED -> ErrorRed.copy(alpha = 0.85f)
    }
    val label = when (notification.status) {
        ZapStatus.SENDING -> "Zapping ${notification.recipientName}"
        ZapStatus.SUCCESS -> "Zapped ${notification.recipientName}"
        is ZapStatus.FAILED -> "Zap failed"
    }
    BasePill(
        icon = NostrVaultIcons.Zap,
        label = label,
        trailingText = "${notification.amountSats} sats",
        backgroundColor = bgColor,
    )
}

// ── Follow ───────────────────────────────────────────────────────

@Composable
fun FollowPill(notification: FollowNotification) {
    val bgColor = when (notification.kind) {
        FollowKind.FOLLOWED -> SuccessGreen
        FollowKind.UNFOLLOWED -> Color(0xFF595959)
        is FollowKind.FAILED -> ErrorRed.copy(alpha = 0.85f)
    }
    val icon = when (notification.kind) {
        FollowKind.FOLLOWED -> NostrVaultIcons.PersonAdd
        FollowKind.UNFOLLOWED -> NostrVaultIcons.Blocked
        is FollowKind.FAILED -> NostrVaultIcons.Dismiss
    }
    val label = when (notification.kind) {
        FollowKind.FOLLOWED -> "Followed ${notification.recipientName}"
        FollowKind.UNFOLLOWED -> "Unfollowed ${notification.recipientName}"
        is FollowKind.FAILED -> notification.kind.reason
    }
    BasePill(icon = icon, label = label, backgroundColor = bgColor)
}

// ── Error ────────────────────────────────────────────────────────

@Composable
fun ErrorPill(notification: ErrorNotification) {
    val bgColor = when (notification.style) {
        ErrorStyle.ERROR -> ErrorRed.copy(alpha = 0.85f)
        ErrorStyle.WARNING -> ZapOrange.copy(alpha = 0.85f)
    }
    BasePill(
        icon = NostrVaultIcons.Alert,
        label = notification.message,
        backgroundColor = bgColor,
        maxLines = 2,
    )
}

// ── Action toast ─────────────────────────────────────────────────

@Composable
fun ActionToastPill(toast: ActionToast) {
    val colors = LocalNostrVaultColors.current
    BasePill(
        icon = NostrVaultIcons.Check,
        label = toast.message,
        backgroundColor = toast.color ?: colors.primary,
    )
}

// ── Upload ───────────────────────────────────────────────────────

@Composable
fun UploadPill(notification: UploadNotification) {
    val bgColor = when (notification.status) {
        UploadStatus.UPLOADING -> LocalNostrVaultColors.current.primary
        UploadStatus.SUCCESS -> SuccessGreen
        is UploadStatus.FAILED -> ErrorRed.copy(alpha = 0.85f)
    }
    val icon = when (notification.status) {
        UploadStatus.UPLOADING -> NostrVaultIcons.UploadIcon
        UploadStatus.SUCCESS -> NostrVaultIcons.Check
        is UploadStatus.FAILED -> NostrVaultIcons.Alert
    }
    val label = when (notification.status) {
        UploadStatus.UPLOADING -> "Uploading ${notification.filename} ${(notification.progress * 100).toInt()}%"
        UploadStatus.SUCCESS -> "Uploaded ${notification.filename}"
        is UploadStatus.FAILED -> "Upload failed"
    }
    BasePill(icon = icon, label = label, backgroundColor = bgColor)
}

// ── Unlike countdown ────────────────────────────────────────────

@Composable
fun UnlikeCountdownPill(notification: UnlikeCountdown, onUndo: () -> Unit) {
    Row(
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(6.dp),
        modifier = Modifier
            .shadow(
                elevation = 8.dp,
                shape = PillShape,
                ambientColor = Color.Black.copy(alpha = 0.4f),
                spotColor = Color.Black.copy(alpha = 0.4f),
            )
            .background(ErrorRed.copy(alpha = 0.85f), PillShape)
            .clip(PillShape)
            .padding(vertical = 6.dp, horizontal = 20.dp),
    ) {
        Icon(
            imageVector = NostrVaultIcons.HeartFilled,
            contentDescription = null,
            tint = Color.White,
            modifier = Modifier.size(14.dp),
        )
        Text(
            // The reaction is already off the note; the deletion goes out
            // when this runs out (iOS #322).
            text = "Reaction removed",
            color = Color.White,
            fontSize = 13.sp,
            fontWeight = FontWeight.Bold,
        )
        androidx.compose.material3.TextButton(
            onClick = onUndo,
            contentPadding = androidx.compose.foundation.layout.PaddingValues(horizontal = 8.dp, vertical = 0.dp),
        ) {
            Text(
                text = "Undo",
                color = Color.White,
                fontSize = 13.sp,
                fontWeight = FontWeight.Bold,
            )
        }
    }
}

// ── Shared base ──────────────────────────────────────────────────

@Composable
private fun BasePill(
    icon: ImageVector,
    label: String,
    backgroundColor: Color,
    trailingText: String? = null,
    maxLines: Int = 1,
) {
    Row(
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(6.dp),
        modifier = Modifier
            .shadow(
                elevation = 8.dp,
                shape = PillShape,
                ambientColor = Color.Black.copy(alpha = 0.4f),
                spotColor = Color.Black.copy(alpha = 0.4f),
            )
            .background(backgroundColor, PillShape)
            .clip(PillShape)
            .padding(vertical = 10.dp, horizontal = 20.dp),
    ) {
        Icon(
            imageVector = icon,
            contentDescription = null,
            tint = Color.White,
            modifier = Modifier.size(14.dp),
        )
        Text(
            text = label,
            color = Color.White,
            fontSize = 13.sp,
            fontWeight = FontWeight.Bold,
            maxLines = maxLines,
        )
        if (trailingText != null) {
            Text(
                text = trailingText,
                color = Color.White,
                fontSize = 13.sp,
                fontWeight = FontWeight.Bold,
            )
        }
    }
}
