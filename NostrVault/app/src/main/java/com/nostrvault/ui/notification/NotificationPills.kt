package com.nostrvault.ui.notification

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.size
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.semantics.LiveRegionMode
import androidx.compose.ui.semantics.liveRegion
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.unit.dp
import com.nostrvault.service.InAppBanner
import com.nostrvault.service.InAppBannerBus
import com.nostrvault.service.PillEnd
import com.nostrvault.ui.navigation.DeepLinkRouter
import com.nostrvault.ui.navigation.NotificationNote
import com.nostrvault.ui.navigation.PendingDeepLink
import com.nostrvault.ui.theme.NostrVaultIcons

/**
 * The pills the lane draws. Every one is a [pillCapsule]: colour says the
 * outcome, the icon says the type, size says whether it takes taps
 * (`docs/pills.md`).
 */

// ── Zap ──────────────────────────────────────────────────────────

/** Sending and sent time out; a failed zap is an error and stays until tapped. */
@Composable
fun ZapPill(notification: ZapNotification, onTap: () -> Unit = {}) {
    val status = notification.status
    val tone = when (status) {
        ZapStatus.SENDING -> PillTone.ACCENT
        ZapStatus.SUCCESS -> PillTone.SUCCESS
        is ZapStatus.FAILED -> PillTone.ERROR
    }
    val label = when (status) {
        ZapStatus.SENDING -> "Zapping ${notification.recipientName}"
        ZapStatus.SUCCESS -> "Zapped ${notification.recipientName}"
        is ZapStatus.FAILED -> status.message.ifBlank { "Zap failed" }
    }
    BasePill(
        icon = if (status is ZapStatus.FAILED) NostrVaultIcons.Alert else NostrVaultIcons.Zap,
        label = label,
        tone = tone,
        trailingText = if (status is ZapStatus.FAILED) null else "${notification.amountSats} sats",
        maxLines = if (status is ZapStatus.FAILED) 2 else 1,
        onClick = if (status is ZapStatus.FAILED) onTap else null,
    )
}

// ── Follow ───────────────────────────────────────────────────────

@Composable
fun FollowPill(notification: FollowNotification, onUndo: () -> Unit = {}) {
    val kind = notification.kind
    if (kind is FollowKind.PENDING) {
        PendingPill(label = (if (kind.follow) "Following " else "Unfollowing ") + notification.recipientName + "…")
        return
    }
    val tone = when (kind) {
        FollowKind.FOLLOWED -> PillTone.SUCCESS
        FollowKind.UNFOLLOWED -> PillTone.NEUTRAL
        is FollowKind.FAILED -> PillTone.ERROR
        is FollowKind.PENDING -> PillTone.NEUTRAL
    }
    val icon = when (kind) {
        FollowKind.FOLLOWED -> NostrVaultIcons.PersonAdd
        FollowKind.UNFOLLOWED -> NostrVaultIcons.Blocked
        is FollowKind.FAILED -> NostrVaultIcons.Dismiss
        is FollowKind.PENDING -> NostrVaultIcons.PersonAdd
    }
    val label = when (kind) {
        FollowKind.FOLLOWED -> "Followed ${notification.recipientName}"
        FollowKind.UNFOLLOWED -> "Unfollowed ${notification.recipientName}"
        is FollowKind.FAILED -> kind.reason
        is FollowKind.PENDING -> notification.recipientName
    }
    val undo = notification.undo
    if (undo == null) {
        BasePill(icon = icon, label = label, tone = tone)
        return
    }
    // The 44 dp Undo button sets the height; the capsule adds no vertical padding.
    Row(
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(PillStyle.innerGap),
        modifier = Modifier.pillCapsule(tone, vertical = 0.dp),
    ) {
        PillIcon(icon)
        PillText(label)
        PillButton("Undo", onClick = onUndo)
    }
}

/**
 * A follow waiting on the follow list: a small spinner where the icon goes,
 * on grey, since it is not an error. iOS `FollowPill` `.pending`.
 */
@Composable
private fun PendingPill(label: String) {
    Row(
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(PillStyle.innerGap),
        modifier = Modifier
            .pillCapsule(PillTone.NEUTRAL)
            .semantics { liveRegion = LiveRegionMode.Polite },
    ) {
        CircularProgressIndicator(color = PillStyle.textColor, strokeWidth = 1.5.dp, modifier = Modifier.size(PillSize.REGULAR.icon))
        PillText(label)
    }
}

// ── Error ────────────────────────────────────────────────────────

/** An error stays until tapped; a warning times out. Either goes on a tap. */
@Composable
fun ErrorPill(notification: ErrorNotification, onTap: () -> Unit = {}) {
    val tone = when (notification.style) {
        ErrorStyle.ERROR -> PillTone.ERROR
        ErrorStyle.WARNING -> PillTone.WARNING
    }
    BasePill(
        icon = NostrVaultIcons.Alert,
        label = notification.message,
        tone = tone,
        maxLines = 2,
        onClick = onTap,
    )
}

// ── Result ───────────────────────────────────────────────────────

@Composable
fun ActionToastPill(toast: ActionToast) {
    BasePill(icon = NostrVaultIcons.Check, label = toast.message, tone = toast.tone, maxLines = 2)
}

// ── Feedback ─────────────────────────────────────────────────────

/** Small, information only: "Link copied", "Liked". */
@Composable
fun FeedbackPill(feedback: FeedbackNotification) {
    Row(
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(PillStyle.innerGap),
        modifier = Modifier
            .pillCapsule(feedback.tone, PillSize.SMALL)
            .semantics(mergeDescendants = true) { liveRegion = LiveRegionMode.Polite },
    ) {
        feedback.icon?.let { PillIcon(it, PillSize.SMALL) }
        PillText(feedback.message, PillSize.SMALL)
    }
}

// ── Activity that arrived while the app was open ─────────────────

/**
 * A mention, reply, zap, reaction, follow or DM that arrived while the app
 * was on screen: one regular pill, in place of the system banner. Tap opens
 * the same place the notification would. iOS `RelayActivityBanner`.
 */
@Composable
fun ActivityPill(banner: InAppBanner) {
    val icon = when (banner.type) {
        "dm", "giftwrap" -> NostrVaultIcons.Messages
        "mention", "quote" -> NostrVaultIcons.At
        "reply" -> NostrVaultIcons.Reply
        "zap" -> NostrVaultIcons.Zap
        "reaction", "like" -> NostrVaultIcons.HeartFilled
        "repost" -> NostrVaultIcons.Repost
        "follow", "followers" -> NostrVaultIcons.PersonAdd
        else -> NostrVaultIcons.Notifications
    }
    val label = if (banner.text.isBlank()) banner.title else "${banner.title} · ${banner.text}"
    BasePill(
        icon = icon,
        label = label,
        tone = PillTone.ACCENT,
        onClick = {
            DeepLinkRouter.fromNotification(
                banner.type, banner.id, banner.author, banner.npub,
                // The post itself, as the tray entry carries it: opens with nothing to fetch.
                event = banner.carried[NotificationNote.EVENT_EXTRA],
                target = banner.carried[NotificationNote.TARGET_EXTRA],
            )?.let { PendingDeepLink.post(it) }
            InAppBannerBus.dismiss(banner.id, PillEnd.TAPPED)
        },
    )
}

// ── Upload ───────────────────────────────────────────────────────

@Composable
fun UploadPill(notification: UploadNotification) {
    val tone = when (notification.status) {
        UploadStatus.UPLOADING -> PillTone.ACCENT
        UploadStatus.SUCCESS -> PillTone.SUCCESS
        is UploadStatus.FAILED -> PillTone.ERROR
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
    BasePill(icon = icon, label = label, tone = tone)
}

// ── Unlike countdown ────────────────────────────────────────────

/** "Reaction removed · Undo": undone, so grey, not red (iOS #322). */
@Composable
fun UnlikeCountdownPill(notification: UnlikeCountdown, onUndo: () -> Unit) {
    Row(
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(PillStyle.innerGap),
        modifier = Modifier.pillCapsule(PillTone.NEUTRAL, vertical = 0.dp),
    ) {
        PillIcon(NostrVaultIcons.HeartFilled)
        // The reaction is already off the note; the deletion goes out
        // when this runs out.
        PillText("Reaction removed")
        PillButton("Undo", onClick = onUndo)
    }
}

// ── Shared base ──────────────────────────────────────────────────

@Composable
private fun BasePill(
    icon: ImageVector,
    label: String,
    tone: PillTone,
    trailingText: String? = null,
    maxLines: Int = 1,
    onClick: (() -> Unit)? = null,
) {
    Row(
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(PillStyle.innerGap),
        modifier = Modifier.pillCapsule(tone, onClick = onClick),
    ) {
        PillIcon(icon)
        PillText(label, maxLines = maxLines)
        if (trailingText != null) PillText(trailingText)
    }
}
