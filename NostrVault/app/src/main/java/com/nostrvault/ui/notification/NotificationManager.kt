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
import androidx.compose.ui.graphics.vector.ImageVector
import com.nostrvault.ui.components.FilterNote
import com.nostrvault.ui.theme.NostrVaultIcons
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

    /**
     * How many the manager keeps; the lane ([PillLane]) decides how many draw.
     * The oldest is dropped past this, so errors left untapped cannot pile up.
     */
    private val MAX_HELD = 5

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

    /**
     * Runs [send] under one zap pill: "Zapping Name · N sats" while it goes
     * out, then the outcome in the same pill. Every zap in the app reports
     * this way (`docs/pills.md`), so none needs a toast of its own.
     */
    suspend fun <T> zapping(recipientName: String, amountSats: Int, send: suspend () -> Result<T>): Result<T> {
        val id = addZap(recipientName, amountSats)
        return send().also { result ->
            result.fold(
                onSuccess = { markZapSuccess(id) },
                onFailure = { markZapFailed(id, it.message ?: "Zap failed") },
            )
        }
    }

    // ── Follow pills ──────────────────────────────────────────

    /**
     * Shows a follow outcome. With [pubkey], a pending pill for that person
     * turns into this one instead of a second pill appearing.
     */
    fun showFollow(recipientName: String, kind: FollowKind, undo: (() -> Unit)? = null, pubkey: String? = null) {
        val pending = pubkey?.let { pendingFollowPill(it) }
        if (pending != null) {
            updateNotification<FollowNotification>(pending.id) {
                it.copy(recipientName = recipientName, kind = kind, undo = undo)
            }
            scheduleDismiss(pending.id, FollowNotification(recipientName = recipientName, kind = kind, undo = undo).autoDismissMs)
            return
        }
        val notification = FollowNotification(recipientName = recipientName, kind = kind, undo = undo, pubkey = pubkey)
        addNotification(notification)
    }

    /**
     * "Following Name…" with a spinner, for a tap queued until the follow
     * list loads. Updates the person's pill if one is already pending.
     * iOS `FollowNotificationManager.addPending`.
     */
    fun addPendingFollow(pubkey: String, recipientName: String, follow: Boolean) {
        val pending = pendingFollowPill(pubkey)
        if (pending != null) {
            updateNotification<FollowNotification>(pending.id) {
                it.copy(recipientName = recipientName, kind = FollowKind.PENDING(follow))
            }
        } else {
            addNotification(FollowNotification(recipientName = recipientName, kind = FollowKind.PENDING(follow), pubkey = pubkey))
        }
    }

    /** Turns [pubkey]'s pending pill, if it has one, into a failure that times out. */
    fun failPendingFollow(pubkey: String, reason: String) {
        val pending = pendingFollowPill(pubkey) ?: return
        showFollow(pending.recipientName, FollowKind.FAILED(reason), pubkey = pubkey)
    }

    /** Takes down [pubkey]'s pending pill without an outcome (the tap was dropped). */
    fun dismissPendingFollow(pubkey: String) {
        pendingFollowPill(pubkey)?.let { dismiss(it.id) }
    }

    /** Every pending pill goes, as on an account switch (iOS `clearPending`). */
    fun clearPendingFollows() {
        _notifications.value
            .filter { it is FollowNotification && it.kind is FollowKind.PENDING }
            .forEach { dismiss(it.id) }
    }

    private fun pendingFollowPill(pubkey: String): FollowNotification? =
        _notifications.value.firstOrNull {
            it is FollowNotification && it.pubkey == pubkey && it.kind is FollowKind.PENDING
        } as FollowNotification?

    // ── Error pills ───────────────────────────────────────────

    fun showError(message: String, style: ErrorStyle = ErrorStyle.ERROR, autoDismissMs: Long? = null) {
        val notification = ErrorNotification(message = message, style = style)
            .let { if (autoDismissMs != null) it.copy(autoDismissMs = autoDismissMs) else it }
        // An error stays until tapped (addNotification schedules the warning's timer).
        addNotification(notification)
    }

    // ── Results ───────────────────────────────────────────────

    /** Something you did finished: a regular pill, green by default, 3 s. */
    fun showToast(message: String, tone: PillTone = PillTone.SUCCESS) {
        addNotification(ActionToast(message = message, tone = tone))
    }

    // ── Feedback ──────────────────────────────────────────────

    /**
     * What a button you just tapped did: a small pill for 2 s. A new one
     * replaces whatever feedback is up; feedback never stacks.
     */
    fun showFeedback(message: String, icon: ImageVector? = NostrVaultIcons.Check, tone: PillTone = PillTone.ACCENT) {
        addNotification(FeedbackNotification(message = message, icon = icon, tone = tone))
    }

    /** A filter note enters as feedback under [id]; its owner times it. */
    fun showFilterNote(id: String, note: FilterNote) {
        if (_notifications.value.any { it.id == id }) {
            updateNotification<FilterNoteNotification>(id) { it.copy(note = note) }
        } else {
            addNotification(FilterNoteNotification(id = id, note = note))
        }
    }

    /** Changes a showing filter note's text; nothing once it has gone, so a late count can't bring it back. */
    fun updateFilterNote(id: String, note: FilterNote) {
        updateNotification<FilterNoteNotification>(id) { it.copy(note = note) }
    }

    /** True while [id] is still held (shown or held back by the lane). */
    fun isShowing(id: String): Boolean = _notifications.value.any { it.id == id }

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
        if (notification.level == PillLevel.FEEDBACK) {
            // Feedback never stacks: the newest replaces the rest.
            current.filter { it.level == PillLevel.FEEDBACK }.forEach { old ->
                current.remove(old)
                dismissJobs.remove(old.id)?.cancel()
            }
        }
        current.add(0, notification) // newest first
        if (current.size > MAX_HELD) {
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
