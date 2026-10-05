package com.nostrvault.ui.navigation

import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow

/**
 * A `nostrvault://mediapaste` link waiting for the Media tab: the nav host
 * sets it and switches tabs, the gallery pastes the clipboard into Blossom
 * once it is on screen. Matches iOS, which opens the Media tab and then
 * fires its magic paste.
 */
object PendingMediaPaste {
    private val _requested = MutableStateFlow(false)
    val requested: StateFlow<Boolean> = _requested

    fun request() { _requested.value = true }

    /** True once per request, so a recomposition does not paste twice. */
    fun consume(): Boolean = _requested.value.also { _requested.value = false }
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
