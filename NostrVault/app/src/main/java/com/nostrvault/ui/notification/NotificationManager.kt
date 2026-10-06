package com.nostrvault.ui.notification

import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch
import javax.inject.Inject
import javax.inject.Singleton

/**
 * Centralised manager for floating notification pills.
 *
 * Matches the iOS pattern of per-type singleton managers, but collapsed
 * into a single @Singleton to keep the Hilt graph simple. All state
 * mutations happen on Main.immediate for thread safety.
 */
@Singleton
class NotificationManager @Inject constructor() {

    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)
    private val dismissJobs = mutableMapOf<String, Job>()

    private val _notifications = MutableStateFlow<List<AppNotification>>(emptyList())
    val notifications: StateFlow<List<AppNotification>> = _notifications.asStateFlow()

    private val MAX_VISIBLE = 5

    // ── Zap pills ──────────────────────────────────────────────

    fun addZap(recipientName: String, amountSats: Int): String {
        val notification = ZapNotification(
            recipientName = recipientName,
            amountSats = amountSats,
            status = ZapStatus.SENDING,
        )
        addNotification(notification)
        return notification.id
    }

    fun markZapSuccess(id: String) {
        updateNotification<ZapNotification>(id) { it.copy(status = ZapStatus.SUCCESS) }
        scheduleDismiss(id, 3_000L)
    }

    fun markZapFailed(id: String, message: String) {
        updateNotification<ZapNotification>(id) { it.copy(status = ZapStatus.FAILED(message)) }
        scheduleDismiss(id, 5_000L)
    }

    // ── Follow pills ──────────────────────────────────────────

    fun showFollow(recipientName: String, kind: FollowKind) {
        val notification = FollowNotification(recipientName = recipientName, kind = kind)
        addNotification(notification)
        scheduleDismiss(notification.id, notification.autoDismissMs)
    }

    // ── Error pills ───────────────────────────────────────────

    fun showError(message: String, style: ErrorStyle = ErrorStyle.ERROR) {
        val notification = ErrorNotification(message = message, style = style)
        addNotification(notification)
        scheduleDismiss(notification.id, notification.autoDismissMs)
    }

    // ── Action toasts ─────────────────────────────────────────

    fun showToast(message: String) {
        val toast = ActionToast(message = message)
        addNotification(toast)
        scheduleDismiss(toast.id, toast.autoDismissMs)
    }

    // ── Upload pills (stub) ───────────────────────────────────

    fun addUpload(filename: String): String {
        val notification = UploadNotification(filename = filename)
        addNotification(notification)
        return notification.id
    }

    fun updateUploadProgress(id: String, progress: Float) {
        updateNotification<UploadNotification>(id) { it.copy(progress = progress) }
    }

    fun markUploadSuccess(id: String) {
        updateNotification<UploadNotification>(id) {
            it.copy(status = UploadStatus.SUCCESS, progress = 1f)
        }
        scheduleDismiss(id, 3_000L)
    }

    fun markUploadFailed(id: String, message: String) {
        updateNotification<UploadNotification>(id) {
            it.copy(status = UploadStatus.FAILED(message))
        }
        scheduleDismiss(id, 5_000L)
    }

    // ── Unlike countdown ──────────────────────────────────────

    private var unlikeJob: Job? = null
    private var unlikeCallback: (() -> Unit)? = null
    private var undoCallback: (() -> Unit)? = null
    private var unlikeNotificationId: String? = null

    /**
     * Shows the "Reaction removed · Undo" pill. When it runs out, [onUnlike]
     * runs (the deletion goes out); Undo runs [onUndo] instead. A countdown
     * already running is committed first rather than dropped.
     */
    fun startUnlikeCountdown(onUnlike: () -> Unit, onUndo: () -> Unit = {}) {
        commitUnlikeCountdown()
        unlikeCallback = onUnlike
        undoCallback = onUndo
        val notification = UnlikeCountdown()
        unlikeNotificationId = notification.id
        addNotification(notification)

        unlikeJob = scope.launch {
            for (i in 30 downTo 0) {
                delay(100)
                updateNotification<UnlikeCountdown>(notification.id) {
                    it.copy(timeRemaining = i / 10f)
                }
            }
            commitUnlikeCountdown()
        }
    }

    /** Ends a running countdown now, as if it had run out. */
    fun commitUnlikeCountdown() {
        val callback = unlikeCallback
        clearUnlikeCountdown()
        callback?.invoke()
    }

    /** The pill's Undo: the countdown ends without its action, and the undo runs. */
    fun undoUnlikeCountdown() {
        val undo = undoCallback
        clearUnlikeCountdown()
        undo?.invoke()
    }

    fun cancelUnlikeCountdown() = clearUnlikeCountdown()

    private fun clearUnlikeCountdown() {
        // Cancelled from inside the countdown's own job too; take what is
        // needed before cancelling it.
        val job = unlikeJob
        unlikeJob = null
        unlikeCallback = null
        undoCallback = null
        unlikeNotificationId?.let { dismiss(it) }
        unlikeNotificationId = null
        job?.cancel()
    }

    // ── Dismiss ───────────────────────────────────────────────

    fun dismiss(id: String) {
        dismissJobs.remove(id)?.cancel()
        _notifications.value = _notifications.value.filter { it.id != id }
    }

    // ── Internal ──────────────────────────────────────────────

    private fun addNotification(notification: AppNotification) {
        val current = _notifications.value.toMutableList()
        current.add(0, notification) // newest first
        if (current.size > MAX_VISIBLE) {
            val removed = current.removeAt(current.lastIndex)
            dismissJobs.remove(removed.id)?.cancel()
        }
        _notifications.value = current

        if (notification.autoDismissMs > 0) {
            scheduleDismiss(notification.id, notification.autoDismissMs)
        }
    }

    private inline fun <reified T : AppNotification> updateNotification(
        id: String,
        transform: (T) -> T,
    ) {
        _notifications.value = _notifications.value.map { n ->
            if (n.id == id && n is T) transform(n) else n
        }
    }

    private fun scheduleDismiss(id: String, delayMs: Long) {
        dismissJobs[id]?.cancel()
        dismissJobs[id] = scope.launch {
            delay(delayMs)
            dismiss(id)
        }
    }
}
