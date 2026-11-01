package com.nostrvault.ui.screens

import androidx.lifecycle.viewModelScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch

// Where picked photos go in the text: the cursor spot each was picked at,
// kept in step with edits, and the link put there once its upload lands.
// The rules themselves are in ComposeNoteDraft.

/** Every edit, typed or inserted, moves the photo spots along; a landed upload places its link. */
internal fun ComposeNoteViewModel.followEditsWithPlacements() {
    viewModelScope.launch { _content.collect { rebaseAnchors() } }
    uploads.onDone = { attachment, done ->
        viewModelScope.launch(Dispatchers.Main) { placeLink(attachment.id, done.media.url) }
    }
}

    /** Adds [added] and starts their uploads; with the cursor inside the text they are placed there. */
    internal fun ComposeNoteViewModel.attach(added: List<Attachment>, caret: Int? = null) {
        // Post is waiting on the uploads it took: a photo added now would upload but never post.
        if (isPublishing.value) {
            added.forEach { com.nostrvault.data.gif.GifCache.deleteIfOwned(it.uri, context.cacheDir) }
            return
        }
        rebaseAnchors()
        ComposeNoteDraft.anchorFor(_content.value, caret)?.let { at ->
            _anchors.value = _anchors.value + added.associate { it.id to at }
        }
        _attachments.value = _attachments.value + added
        added.forEach { uploads.start(it) }
    }

    /** Moves the photo spots to the current text (one edit since the last call). */
    internal fun ComposeNoteViewModel.rebaseAnchors() {
        val now = _content.value
        if (now == anchorText) return
        if (_anchors.value.isNotEmpty()) {
            _anchors.value = _anchors.value.mapValues { (_, at) -> ComposeNoteDraft.shift(anchorText, now, at) }
        }
        anchorText = now
    }

    /** A placed photo's upload landed: its link goes in where it was picked. */
    internal fun ComposeNoteViewModel.placeLink(id: String, url: String?) {
        rebaseAnchors()
        val at = _anchors.value[id] ?: return
        // Saved on this device only: its link comes at Post, and goes in here then.
        if (url == null) return
        _anchors.value = _anchors.value - id
        if (_attachments.value.none { it.id == id }) return
        val (text, _, _) = ComposeNoteDraft.insertLink(_content.value, at, url)
        _content.value = text
        rebaseAnchors()
        scheduleDraftSave()
    }

