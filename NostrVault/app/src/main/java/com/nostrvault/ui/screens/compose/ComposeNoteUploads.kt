package com.nostrvault.ui.screens

import com.nostrvault.data.model.QueuedMediaPost
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Job
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock

/**
 * The composer's uploads, started the moment a photo is picked instead of
 * when Post is tapped.
 *
 * They run one at a time in the order picked, as the old loop in publish
 * did. Its "servers down, save the rest here" rule stays per Post ([await]). [send] is that loop's body for one attachment
 * ([ComposeNoteViewModel.uploadOne]); the host list, location stripping and
 * on-device fallback live there, unchanged.
 *
 * [scope] must outlive the screen while a post waits on these (see
 * [ComposeNoteViewModel.publish]).
 */
internal class ComposeNoteUploads(
    private val scope: CoroutineScope,
    private val send: suspend (attachment: Attachment, skipOutside: Boolean, onProgress: (Float) -> Unit) -> ComposeNoteUpload,
    /** Media picked from the relay: already hosted, published as-is. */
    private val hostedMedia: (Attachment) -> QueuedMediaPost.Media,
) {
    private val _states = MutableStateFlow<Map<String, ComposeNoteUpload>>(emptyMap())
    val states: StateFlow<Map<String, ComposeNoteUpload>> = _states.asStateFlow()

    private val jobs = mutableMapOf<String, Job>()
    /** One upload at a time; a Mutex hands the lock out in arrival order. */
    private val turn = Mutex()
    /** Called once a link is known, so the screen can place it. */
    var onDone: ((Attachment, ComposeNoteUpload.Done) -> Unit)? = null

    /** Starts [attachment]'s upload; one already hosted is done at once. */
    fun start(attachment: Attachment) {
        if (attachment.hostedUrl != null) return
        set(attachment.id, ComposeNoteUpload.Waiting)
        synchronized(jobs) {
            jobs[attachment.id] = scope.launch { run(attachment) }
        }
    }

    /** A pick never skips the outside servers: the "servers down" rule is per Post, as it was. */
    private suspend fun run(attachment: Attachment, skipOutside: Boolean = false) {
        val result = turn.withLock {
            set(attachment.id, ComposeNoteUpload.Sending(0f))
            send(attachment, skipOutside) { progress ->
                if (_states.value[attachment.id] is ComposeNoteUpload.Sending) set(attachment.id, ComposeNoteUpload.Sending(progress))
            }
        }
        if (attachment.id !in _states.value) return // removed meanwhile
        set(attachment.id, result)
        if (result is ComposeNoteUpload.Done) onDone?.invoke(attachment, result)
    }

    /** The photo was removed: stop its upload and forget it. */
    fun cancel(id: String) {
        synchronized(jobs) { jobs.remove(id) }?.cancel()
        _states.update { it - id }
    }

    /** The composer closed without posting. */
    fun cancelAll() {
        val all = synchronized(jobs) { jobs.values.toList().also { jobs.clear() } }
        all.forEach { it.cancel() }
        _states.value = emptyMap()
    }

    /**
     * Waits for every one of [attachments] and returns the post's media in
     * their order, as the old publish loop did. What has no outside link yet
     * (a failed upload, or one saved on this device only while the servers
     * were down) is tried again now, as Post always did; and as before, once
     * one of this Post's tries finds every outside server down, the rest are
     * saved here only rather than each waiting out the same retry.
     */
    suspend fun await(attachments: List<Attachment>): ComposeNoteViewModel.AttachmentUploadResult {
        val media = mutableListOf<QueuedMediaPost.Media>()
        var unreachable = emptyList<String>()
        for (attachment in attachments) {
            if (attachment.hostedUrl != null) {
                media += hostedMedia(attachment)
                continue
            }
            synchronized(jobs) { jobs[attachment.id] }?.join()
            var state = _states.value[attachment.id]
            if (state !is ComposeNoteUpload.Done || state.media.url == null) {
                set(attachment.id, ComposeNoteUpload.Waiting)
                run(attachment, skipOutside = unreachable.isNotEmpty())
                state = _states.value[attachment.id]
            }
            when (state) {
                is ComposeNoteUpload.Done -> {
                    if (state.unreachable.isNotEmpty()) unreachable = state.unreachable
                    media += state.media.copy(alt = attachment.altText)
                }
                is ComposeNoteUpload.Failed -> return ComposeNoteViewModel.AttachmentUploadResult.Failed(state.message)
                else -> return ComposeNoteViewModel.AttachmentUploadResult.Failed(
                    com.nostrvault.data.model.MediaUploadOutcomeMessage.NOT_SAVED_ON_DEVICE,
                )
            }
        }
        return ComposeNoteViewModel.AttachmentUploadResult.Done(media, unreachable)
    }

    private fun set(id: String, state: ComposeNoteUpload) = _states.update { it + (id to state) }

}
