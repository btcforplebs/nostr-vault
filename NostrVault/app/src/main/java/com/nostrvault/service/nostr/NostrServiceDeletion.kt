package com.nostrvault.service

import android.util.Log
import com.nostrvault.service.NostrService.Companion.TAG
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

/**
 * Deleting one of your own posts. Lives outside `NostrService.kt`, which is
 * over the file-size limit; see `deleteOwnEvents` there for the blob-driven
 * variant. iOS twin: `NostrService+Moderation.swift`.
 */

/**
 * Publishes a NIP-09 deletion request (kind 5) for [noteId], then drops the
 * post from [NostrService.events] so your Posts and Media lists stop showing
 * it before the next reload. Signing failures leave the list alone, like
 * [NostrService.deleteOwnEvents].
 */
fun NostrService.deleteNote(noteId: String) {
    scope.launch(Dispatchers.IO) {
        val signed = try {
            signEventAsync(kind = 5, content = "", tags = NoteDeletion.requestTags(noteId))
        } catch (e: Exception) {
            Log.e(TAG, "deleteNote: not signed: ${e.message}")
            null
        } ?: return@launch
        postEvent(signed)
        withContext(Dispatchers.Main) {
            events = NoteDeletion.without(events, noteId)
            _eventUpdates.tryEmit(Unit)
        }
    }
}
