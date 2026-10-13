package com.nostrvault.ui.notification

import androidx.compose.ui.graphics.vector.ImageVector
import com.nostrvault.ui.components.FilterNote
import java.util.UUID

/**
 * Sealed hierarchy for all floating notification pill types.
 * Each subclass carries its display data, its lane level and its
 * auto-dismiss duration (0 = until something else takes it down).
 */
sealed class AppNotification {
    abstract val id: String
    abstract val level: PillLevel
    abstract val autoDismissMs: Long
}

// ── Zap ──────────────────────────────────────────────────────────

data class ZapNotification(
    override val id: String = UUID.randomUUID().toString(),
    val recipientName: String,
    val amountSats: Int,
    val status: ZapStatus,
) : AppNotification() {
    override val level: PillLevel get() = if (status is ZapStatus.FAILED) PillLevel.ERROR else PillLevel.RESULT
    override val autoDismissMs: Long
        get() = when (status) {
            ZapStatus.SENDING -> 0L
            ZapStatus.SUCCESS -> 3_000L
            is ZapStatus.FAILED -> 5_000L
        }
}

sealed class ZapStatus {
    data object SENDING : ZapStatus()
    data object SUCCESS : ZapStatus()
    data class FAILED(val message: String) : ZapStatus()
}

// ── Follow ───────────────────────────────────────────────────────

data class FollowNotification(
    override val id: String = UUID.randomUUID().toString(),
    val recipientName: String,
    val kind: FollowKind,
    /** Reverses the follow; the pill shows Undo and stays up longer. */
    val undo: (() -> Unit)? = null,
    /** Whose follow this is, so a pending pill can turn into its outcome. */
    val pubkey: String? = null,
) : AppNotification() {
    override val level: PillLevel get() = if (kind is FollowKind.FAILED) PillLevel.ERROR else PillLevel.RESULT
    override val autoDismissMs: Long
        get() = when (kind) {
            FollowKind.FOLLOWED, FollowKind.UNFOLLOWED -> if (undo != null) 5_000L else 3_000L
            is FollowKind.FAILED -> 5_000L
            // Stays up until the queued tap is applied or dropped.
            is FollowKind.PENDING -> 0L
        }
}

sealed class FollowKind {
    data object FOLLOWED : FollowKind()
    data object UNFOLLOWED : FollowKind()
    data class FAILED(val reason: String) : FollowKind()
    /** Tapped before the follow list loaded; applied once it has (iOS `.pending`). Not an error. */
    data class PENDING(val follow: Boolean) : FollowKind()
}

// ── Error ────────────────────────────────────────────────────────

/** An error stays until tapped; a warning goes after 5 s (`docs/pills.md`). */
data class ErrorNotification(
    override val id: String = UUID.randomUUID().toString(),
    val message: String,
    val style: ErrorStyle = ErrorStyle.ERROR,
    override val autoDismissMs: Long = if (style == ErrorStyle.WARNING) 5_000L else 0L,
) : AppNotification() {
    override val level: PillLevel get() = PillLevel.ERROR
}

enum class ErrorStyle { ERROR, WARNING }

// ── Action toast (a result) ──────────────────────────────────────

/** Something you did finished: "Saved to gallery", "Deleted everywhere". */
data class ActionToast(
    override val id: String = UUID.randomUUID().toString(),
    val message: String,
    val tone: PillTone = PillTone.SUCCESS,
    override val autoDismissMs: Long = 3_000L,
) : AppNotification() {
    override val level: PillLevel get() = PillLevel.RESULT
}

// ── Feedback ─────────────────────────────────────────────────────

/**
 * What a button you just tapped did: "Link copied", "Liked". Small, 2 s,
 * and a new one replaces the old one.
 */
data class FeedbackNotification(
    override val id: String = UUID.randomUUID().toString(),
    val message: String,
    /** The type's icon; null for text alone. */
    val icon: ImageVector? = null,
    /** Accent for on / done, neutral for off / hidden. */
    val tone: PillTone = PillTone.ACCENT,
    override val autoDismissMs: Long = 2_000L,
) : AppNotification() {
    override val level: PillLevel get() = PillLevel.FEEDBACK
}

/**
 * The line a filter tap leaves ("Mentions · on · 18"). Feedback, so it takes
 * the place of any other feedback; its timing is the owning
 * [com.nostrvault.ui.components.FilterNoteState]'s, not the manager's.
 */
data class FilterNoteNotification(
    override val id: String,
    val note: FilterNote,
) : AppNotification() {
    override val level: PillLevel get() = PillLevel.FEEDBACK
    override val autoDismissMs: Long get() = 0L
}

// ── Upload ───────────────────────────────────────────────────────

data class UploadNotification(
    override val id: String = UUID.randomUUID().toString(),
    val filename: String,
    val status: UploadStatus = UploadStatus.UPLOADING,
    val progress: Float = 0f,
) : AppNotification() {
    override val level: PillLevel get() = if (status is UploadStatus.FAILED) PillLevel.ERROR else PillLevel.RESULT
    override val autoDismissMs: Long
        get() = when (status) {
            UploadStatus.UPLOADING -> 0L
            UploadStatus.SUCCESS -> 3_000L
            is UploadStatus.FAILED -> 5_000L
        }
}

sealed class UploadStatus {
    data object UPLOADING : UploadStatus()
    data object SUCCESS : UploadStatus()
    data class FAILED(val message: String) : UploadStatus()
}

// ── Unlike countdown ────────────────────────────────────────────

data class UnlikeCountdown(
    override val id: String = UUID.randomUUID().toString(),
    val timeRemaining: Float = 3.0f,
    override val autoDismissMs: Long = 0L, // Managed by countdown coroutine
) : AppNotification() {
    override val level: PillLevel get() = PillLevel.RESULT
}
