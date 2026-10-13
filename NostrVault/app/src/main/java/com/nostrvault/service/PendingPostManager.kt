package com.nostrvault.service

import android.content.Context
import android.util.Log
import dagger.hilt.android.qualifiers.ApplicationContext
import com.nostrvault.data.model.FeedNote
import kotlinx.coroutines.*
import kotlinx.coroutines.flow.MutableSharedFlow
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.SharedFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asSharedFlow
import kotlinx.coroutines.flow.asStateFlow
import javax.inject.Inject
import javax.inject.Singleton

/**
 * Manages the send-delay countdown (Off, 5s or 10s; 5s by default) before
 * publishing events.
 * Allows the user to cancel or edit before the post goes live.
 * Port of PendingPostManager.swift.
 */
@Singleton
class PendingPostManager @Inject constructor(
    @ApplicationContext context: Context,
) {

    companion object {
        private const val TAG = "PendingPostManager"
        private const val TICK_INTERVAL_MS = 100L

        /** The choices offered in Settings. 0 = Off: no banner, no undo. */
        val SEND_DELAY_CHOICES = listOf(0, 5, 10)
        const val SEND_DELAY_DEFAULT = 5
        private const val PREFS_NAME = "post_preferences"
        private const val KEY_SEND_DELAY = "send_delay_seconds"
    }

    private val prefs = context.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)

    private val _sendDelaySeconds = MutableStateFlow(
        prefs.getInt(KEY_SEND_DELAY, SEND_DELAY_DEFAULT).takeIf { it in SEND_DELAY_CHOICES }
            ?: SEND_DELAY_DEFAULT,
    )
    /** Read fresh by each action, so a change applies to the next post. */
    val sendDelaySeconds: StateFlow<Int> = _sendDelaySeconds.asStateFlow()

    fun setSendDelaySeconds(seconds: Int) {
        if (seconds !in SEND_DELAY_CHOICES) return
        _sendDelaySeconds.value = seconds
        prefs.edit().putInt(KEY_SEND_DELAY, seconds).apply()
    }

    /** The length of the countdown in flight, so the banner's ring is scaled
     *  to the delay this action started with. */
    private val _totalSeconds = MutableStateFlow(SEND_DELAY_DEFAULT.toFloat())
    val totalSeconds: StateFlow<Float> = _totalSeconds.asStateFlow()

    enum class ActionType(val label: String, val canEdit: Boolean, val doneLabel: String) {
        NEW_POST("Posting", true, "Posted"),
        REPLY("Replying", true, "Replied"),
        QUOTE("Quoting", true, "Quoted"),
        REPOST("Reposting", false, "Reposted"),
        DELETE("Deleting", false, "Deleted"),
    }

    /**
     * What happened after the countdown: sending, then either a relay took it
     * (green) or none confirmed it after the retries (grey, not red: it was
     * sent, and a slow relay is not a failed post).
     */
    data class Confirmation(val id: Long, val actionType: ActionType, val state: State) {
        enum class State { SENDING, CONFIRMED, UNCONFIRMED }
    }

    /**
     * Edit on the banner: what the composer reopens with. [draftId] is the
     * saved draft backing the post, so the reopened composer resumes it
     * instead of starting a second one; [replyToId] and [quoteToId] are the
     * composer's own route arguments, kept even when the note itself is not
     * in memory.
     */
    data class EditRequest(
        val content: String,
        val replyTo: FeedNote?,
        val quoteTo: FeedNote?,
        val draftId: String? = null,
        val replyToId: String? = null,
        val quoteToId: String? = null,
    )

    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)

    /**
     * Draft ids whose post is on its way: uploading or signing in
     * [launchSend], then in the countdown until it is sent or taken back.
     * The draft is still on disk for all of that, so it can be reopened.
     */
    private val sendingDrafts = java.util.Collections.synchronizedSet(mutableSetOf<String>())

    /** True while the post backed by [draftId] is still on its way (see [sendingDrafts]). */
    fun isSending(draftId: String): Boolean = draftId in sendingDrafts

    /**
     * Runs a post's send (upload, signing, hand-off to the countdown) on this
     * app-lifetime scope, so leaving the composer mid-send does not cancel it.
     * iOS gets the same from an unstructured Task plus background time in
     * ComposeView.postNote. Returns null, and runs nothing, when [draftId] is
     * already sending: the composer can be left and the same draft reopened
     * from Drafts while its first send is still going.
     */
    fun launchSend(draftId: String, block: suspend CoroutineScope.() -> Unit): Job? {
        if (!sendingDrafts.add(draftId)) return null
        return scope.launch(block = block).also { job ->
            job.invokeOnCompletion {
                // Handed to the countdown: held until that sends it or it is
                // taken back (see startCountdown and cancel). Otherwise the
                // send failed or queued the post, and the draft is free.
                if (pendingDraftId != draftId) sendingDrafts.remove(draftId)
            }
        }
    }

    private val _isShowing = MutableStateFlow(false)
    val isShowing: StateFlow<Boolean> = _isShowing.asStateFlow()

    private val _actionType = MutableStateFlow<ActionType?>(null)
    val actionType: StateFlow<ActionType?> = _actionType.asStateFlow()

    private val _timeRemaining = MutableStateFlow(0f)
    val timeRemaining: StateFlow<Float> = _timeRemaining.asStateFlow()

    private val _confirmation = MutableStateFlow<Confirmation?>(null)
    val confirmation: StateFlow<Confirmation?> = _confirmation.asStateFlow()
    private var nextConfirmationId = 0L

    private val _editRequest = MutableSharedFlow<EditRequest>(extraBufferCapacity = 1)
    val editRequest: SharedFlow<EditRequest> = _editRequest.asSharedFlow()

    /**
     * The id of a post taken back before it went out (Cancel, Edit, or a new
     * action replacing it). The thread showed it optimistically, so it has
     * to come out again; NoteDetailViewModel listens. iOS removes it from
     * FeedService in cancel()/requestEdit()/clearPrevious().
     */
    private val _withdrawn = MutableSharedFlow<String>(extraBufferCapacity = 8)
    val withdrawn: SharedFlow<String> = _withdrawn.asSharedFlow()

    private var countdownJob: Job? = null
    private var pendingContent: String = ""
    private var pendingReplyTo: FeedNote? = null
    private var pendingQuoteTo: FeedNote? = null
    private var pendingDraftId: String? = null
    private var pendingReplyToId: String? = null
    private var pendingQuoteToId: String? = null
    /** The signed post in the countdown; null once it is sent or dropped. */
    private var pendingEventId: String? = null
    /** Keeps the post's text as a draft when it is taken back. */
    private var pendingOnWithdrawn: (() -> Unit)? = null
    private var pendingPublishAction: (() -> Unit)? = null

    /**
     * [draftId] is the draft backing this post. The caller deletes it only
     * once the post goes out (inside [onPublish]), and [onWithdrawn] saves it
     * when the post is taken back instead (Cancel, Edit, or a newer action
     * replacing it), before Edit reopens the composer on it. So undoing a
     * post never loses its text. [content] is the text Edit brings back.
     */
    fun startPost(
        event: NostrEvent,
        content: String,
        replyTo: FeedNote?,
        quoteTo: FeedNote?,
        draftId: String? = null,
        replyToId: String? = replyTo?.id,
        quoteToId: String? = quoteTo?.id,
        onWithdrawn: () -> Unit = {},
        onPublish: (NostrEvent, onOutcome: (BroadcastTally.Outcome?) -> Unit) -> Unit,
    ) {
        val type = when {
            quoteToId != null -> ActionType.QUOTE
            replyToId != null -> ActionType.REPLY
            else -> ActionType.NEW_POST
        }
        cancel()
        pendingContent = content
        pendingReplyTo = replyTo
        pendingQuoteTo = quoteTo
        pendingDraftId = draftId
        pendingReplyToId = replyToId
        pendingQuoteToId = quoteToId
        pendingEventId = event.id
        pendingOnWithdrawn = onWithdrawn
        startCountdown(type) {
            // Past the countdown the post is committed: no longer pending, so
            // nothing after this takes it back out of the thread.
            if (pendingEventId == event.id) pendingEventId = null
            // Shown once the countdown ends; the outcome swaps it for
            // "Posted" or the grey not-confirmed note.
            val id = beginConfirmation(type)
            onPublish(event) { outcome -> finishConfirmation(id, outcome) }
        }
    }

    private fun beginConfirmation(type: ActionType): Long {
        val id = ++nextConfirmationId
        _confirmation.value = Confirmation(id, type, Confirmation.State.SENDING)
        return id
    }

    /** null outcome: nothing was sent, so just clear it. Main thread. */
    private fun finishConfirmation(id: Long, outcome: BroadcastTally.Outcome?) {
        val current = _confirmation.value
        if (current?.id != id) return
        if (outcome == null) {
            _confirmation.value = null
            return
        }
        val accepted = outcome == BroadcastTally.Outcome.ACCEPTED
        _confirmation.value = current.copy(
            state = if (accepted) Confirmation.State.CONFIRMED else Confirmation.State.UNCONFIRMED,
        )
        scope.launch {
            delay(if (accepted) 2_500L else 4_000L)
            if (_confirmation.value?.id == id) _confirmation.value = null
        }
    }

    fun startRepost(onPublish: () -> Unit) {
        cancel()
        startCountdown(ActionType.REPOST, onPublish)
    }

    fun startDelete(onDelete: () -> Unit) {
        cancel()
        startCountdown(ActionType.DELETE, onDelete)
    }

    /**
     * Hides the countdown banner without touching the pending action — the
     * swipe gesture on the banner. The countdown job and the publish that
     * follows it keep running; this is the opposite of [cancel].
     */
    fun dismissBanner() {
        if (!_isShowing.value) return
        _isShowing.value = false
    }

    /**
     * Cancel on the banner (the undo): the action never runs. A post's draft
     * is left alone (it is the user's text, still in Drafts), and the post
     * shown in its thread ahead of time is taken out again.
     */
    fun cancel() {
        countdownJob?.cancel()
        countdownJob = null
        pendingPublishAction = null
        pendingEventId?.let { id ->
            runCatching { pendingOnWithdrawn?.invoke() }
                .onFailure { Log.e(TAG, "Keeping the draft failed", it) }
            _withdrawn.tryEmit(id)
        }
        // Taken back: the draft can be edited and posted again.
        pendingDraftId?.let { sendingDrafts.remove(it) }
        clearPendingPost()
        _isShowing.value = false
        _actionType.value = null
        _timeRemaining.value = 0f
    }

    private fun clearPendingPost() {
        pendingEventId = null
        pendingOnWithdrawn = null
        pendingContent = ""
        pendingReplyTo = null
        pendingQuoteTo = null
        pendingDraftId = null
        pendingReplyToId = null
        pendingQuoteToId = null
    }

    fun requestEdit() {
        val type = _actionType.value
        if (type?.canEdit != true) return
        val request = EditRequest(
            content = pendingContent,
            replyTo = pendingReplyTo,
            quoteTo = pendingQuoteTo,
            draftId = pendingDraftId,
            replyToId = pendingReplyToId,
            quoteToId = pendingQuoteToId,
        )
        cancel()
        _editRequest.tryEmit(request)
    }

    private fun startCountdown(type: ActionType, onComplete: () -> Unit) {
        _confirmation.value = null
        pendingPublishAction = onComplete
        val durationMs = _sendDelaySeconds.value * 1000L
        _actionType.value = type
        _totalSeconds.value = durationMs / 1000f
        _timeRemaining.value = durationMs / 1000f
        // With the delay Off the banner never appears; the job below runs the
        // action on its first pass.
        _isShowing.value = durationMs > 0

        countdownJob = scope.launch {
            val steps = (durationMs / TICK_INTERVAL_MS).toInt()
            for (i in steps downTo 0) {
                _timeRemaining.value = (i * TICK_INTERVAL_MS) / 1000f
                if (i > 0) delay(TICK_INTERVAL_MS)
            }

            // Countdown complete — publish
            try {
                pendingPublishAction?.invoke()
            } catch (e: Exception) {
                Log.e(TAG, "Publish failed", e)
                // Nothing went out, so no outcome will ever arrive.
                _confirmation.value = null
            }

            _isShowing.value = false
            _actionType.value = null
            pendingPublishAction = null
            // Sent: the post's draft is no longer on its way.
            pendingDraftId?.let { sendingDrafts.remove(it) }
            clearPendingPost()
        }
    }
}
