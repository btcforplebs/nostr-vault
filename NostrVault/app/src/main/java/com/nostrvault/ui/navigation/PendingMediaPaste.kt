package com.nostrvault.ui.navigation

import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow

/**
 * A `nostrvault://mediapaste` link waiting for the Media tab: the nav host
 * sets it and switches tabs, and once the gallery is on screen it asks
 * before pasting the clipboard into Blossom. Any app or web page can fire
 * that link, and iOS has the system paste prompt where Android has none, so
 * nothing is uploaded until the person confirms (Tron, 3.0.0 42 pre-flight).
 */
object PendingMediaPaste {
    private val _requested = MutableStateFlow(false)
    val requested: StateFlow<Boolean> = _requested

    /** The gallery is on screen and asking "Upload what's on your clipboard?". */
    private val _awaitingConfirm = MutableStateFlow(false)
    val awaitingConfirm: StateFlow<Boolean> = _awaitingConfirm

    fun request() { _requested.value = true }

    /**
     * True once per request, so a recomposition does not ask twice. Taking the
     * request opens the confirm; it never pastes by itself.
     */
    fun consume(): Boolean = _requested.value.also {
        _requested.value = false
        if (it) _awaitingConfirm.value = true
    }

    /** The person tapped Upload: true once, and only while the confirm was up. */
    fun confirm(): Boolean = _awaitingConfirm.value.also { _awaitingConfirm.value = false }

    /** The person cancelled or dismissed the confirm: nothing is pasted. */
    fun cancel() { _awaitingConfirm.value = false }
}

/** What a clipboard paste into the Media tab saves, as iOS handlePasteFromClipboard reads it. */
sealed interface ClipboardMedia {
    /** Copied media (an image from another app arrives as a content URI). */
    data class ContentUri(val uri: String) : ClipboardMedia
    /** A copied http(s) link, downloaded into the vault. */
    data class Link(val url: String) : ClipboardMedia
    /** Copied text that is not a link. */
    data object NotALink : ClipboardMedia
    data object Empty : ClipboardMedia

    companion object {
        /** Media first, then a link, as iOS does. */
        fun from(uri: String?, text: String?): ClipboardMedia {
            if (!uri.isNullOrBlank()) return ContentUri(uri)
            val trimmed = text?.trim().orEmpty()
            if (trimmed.isEmpty()) return Empty
            val lower = trimmed.lowercase()
            val isLink = (lower.startsWith("https://") || lower.startsWith("http://")) &&
                trimmed.none { it.isWhitespace() } && trimmed.substringAfter("://").isNotEmpty()
            return if (isLink) Link(trimmed) else NotALink
        }
    }
}
