package com.nostrvault.ui.notification

import androidx.compose.ui.graphics.Color
import java.util.UUID

/**
 * Sealed hierarchy for all floating notification pill types.
 * Each subclass carries its display data and auto-dismiss duration.
 */
sealed class AppNotification {
    abstract val id: String
    abstract val autoDismissMs: Long
}

// ── Zap ──────────────────────────────────────────────────────────

data class ZapNotification(
    override val id: String = UUID.randomUUID().toString(),
    val recipientName: String,
    val amountSats: Int,
    val status: ZapStatus,
) : AppNotification() {
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
) : AppNotification() {
    override val autoDismissMs: Long
        get() = when (kind) {
            FollowKind.FOLLOWED, FollowKind.UNFOLLOWED -> if (undo != null) 5_000L else 3_000L
            is FollowKind.FAILED -> 5_000L
        }
}

sealed class FollowKind {
    data object FOLLOWED : FollowKind()
    data object UNFOLLOWED : FollowKind()
    data class FAILED(val reason: String) : FollowKind()
}

// ── Error ────────────────────────────────────────────────────────

data class ErrorNotification(
    override val id: String = UUID.randomUUID().toString(),
    val message: String,
    val style: ErrorStyle = ErrorStyle.ERROR,
    override val autoDismissMs: Long = 5_000L,
) : AppNotification()

enum class ErrorStyle { ERROR, WARNING }

// ── Action toast ─────────────────────────────────────────────────

data class ActionToast(
    override val id: String = UUID.randomUUID().toString(),
    val message: String,
    val color: Color? = null,
    override val autoDismissMs: Long = 2_500L,
) : AppNotification()

// ── Upload (stubbed for future wiring) ───────────────────────────

data class UploadNotification(
    override val id: String = UUID.randomUUID().toString(),
    val filename: String,
    val status: UploadStatus = UploadStatus.UPLOADING,
    val progress: Float = 0f,
) : AppNotification() {
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
) : AppNotification()
