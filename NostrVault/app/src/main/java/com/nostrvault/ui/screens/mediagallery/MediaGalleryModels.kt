package com.nostrvault.ui.screens

import androidx.compose.foundation.layout.*
import androidx.compose.material3.*
import androidx.compose.runtime.*
import com.nostrvault.service.*
import com.nostrvault.ui.theme.*
import kotlinx.coroutines.*
import kotlinx.coroutines.flow.*
import java.io.File

/**
 * The http(s) link a pasted string names, or null. Port of the URL check in
 * iOS `handlePasteFromClipboard`: anything without an http(s) scheme and a
 * host is not something to download.
 */
internal fun pastedMediaUrl(text: String): String? {
    val trimmed = text.trim()
    if (trimmed.isEmpty() || trimmed.any { it.isWhitespace() }) return null
    val uri = runCatching { java.net.URI(trimmed) }.getOrNull() ?: return null
    val scheme = uri.scheme?.lowercase()
    if (scheme != "http" && scheme != "https") return null
    if (uri.host.isNullOrEmpty()) return null
    return trimmed
}

/**
 * Whether a pasted link may be fetched: http(s) to a public host only. The
 * clipboard is set by other apps, so a loopback or LAN link would have us
 * request our own relay or a host on the user's network. Resolves the name,
 * so call off the main thread.
 */
internal fun pastedUrlIsPublic(url: String): Boolean =
    com.nostrvault.util.UrlSafety.isSafeRemoteUrl(url)

/** Shown when a pasted link points at this device or the local network. */
internal const val PASTED_URL_REFUSED = "That link points at this device or your local network"

internal const val MEDIA_GALLERY_PREFS = "media_gallery"


/** Lightweight bridge so MediaViewerScreen can access the gallery's current filtered media list. */
object MediaGalleryBridge {
    var currentItems: List<BlossomMediaItem> = emptyList()
}

/** What the Media tab shows instead of the grid. Port of iOS `MediaGalleryGrid.mediaContent`. */
internal enum class MediaEmptyState(val title: String, val detail: String?) {
    /** Nothing to show yet and a scan is running. */
    LOADING("Loading media…", "Scanning for uploads"),
    /** There is media, but the type filter hides all of it. */
    FILTERED("No media found", "Try changing your filter settings"),
    /** No media at all. */
    NONE("No media found", null),
}

/** Null when there is something to show; [total] is before the filter, [shown] after. */
internal fun mediaEmptyState(total: Int, shown: Int, isLoading: Boolean): MediaEmptyState? = when {
    shown > 0 -> null
    isLoading -> MediaEmptyState.LOADING
    total > 0 -> MediaEmptyState.FILTERED
    else -> MediaEmptyState.NONE
}

data class BlossomMediaItem(
    val sha256: String,
    val displayUrl: String,
    val localFile: File?,
    val mimeType: String?,
    val size: Long?,
    val uploaded: Long?,
    val lastModified: Long?,
    val isLocal: Boolean,
    val noteId: String? = null,
    /** Seconds: created_at of the note that posted this file, where one has been seen. */
    val postedAt: Long? = null,
) {
    val isVideo: Boolean get() = mimeType?.startsWith("video") == true
    val isImage: Boolean get() = mimeType?.startsWith("image") == true || mimeType == "image"
    /** By type, or by extension when the server only says octet-stream (iOS sniffs the same way). */
    val isAudio: Boolean get() = mimeType?.startsWith("audio") == true ||
        (!isImage && !isVideo && com.nostrvault.ui.components.isAudioUrl(localFile?.name ?: displayUrl))

    /**
     * Seconds since epoch the gallery orders by: when the note that posted it
     * was made (iOS orders by the note's created_at too), else upload time,
     * else file mtime. Upload time and mtime are when a copy landed, so a file
     * mirrored or moved in today would otherwise jump to the top.
     */
    val sortTime: Long get() = postedAt ?: uploaded ?: lastModified?.div(1000) ?: 0L

    /** GIF detection by extension or mime type, matching iOS MediaGallery isGif. */
    val isGif: Boolean get() =
        mimeType?.contains("gif", ignoreCase = true) == true ||
            displayUrl.substringBefore('?').substringBefore('#')
                .substringAfterLast('.', "").equals("gif", ignoreCase = true)
}

data class MediaItem(val url: String, val noteId: String)

/**
 * Who Report Media / Block User on a tile act on: the author of the note the
 * blob was posted in, when that is someone else. Null — the items hidden —
 * when no note is known, or it is yours (owner or the account in use).
 * iOS MediaGridItem: `item.pubkey != nostrService.activeHexPubkey`.
 */
internal fun mediaModerationTarget(author: String?, ownerHex: String, activeHex: String): String? =
    author?.takeIf { it.isNotEmpty() && it != ownerHex && it != activeHex }

/** Scope for a pending destructive delete in MediaViewerScreen. */
enum class DeleteScope { MIRRORS, EVERYWHERE }

/** Media type filter matching iOS MediaTypeFilter. */
enum class MediaTypeFilter {
    ALL, PHOTO, VIDEO, GIF, OTHER;

    /**
     * Whether [item] belongs under this filter. Shared by the Media tab and
     * the composer's relay picker so the two can't drift.
     */
    fun matches(item: BlossomMediaItem): Boolean = when (this) {
        ALL -> true
        PHOTO -> item.isImage && !item.isGif
        VIDEO -> item.isVideo
        GIF -> item.isGif
        OTHER -> !item.isImage && !item.isVideo
    }
}

/** Gallery layout mode. */
enum class MediaLayoutMode { GRID, LIST }

/** [items] with each file's post date from [postDates] (hash -> seconds), where one is known. */
internal fun withPostDates(items: List<BlossomMediaItem>, postDates: Map<String, Long>): List<BlossomMediaItem> =
    if (postDates.isEmpty()) items
    else items.map { item ->
        val at = postDates[item.sha256.lowercase()]
        if (at == null || at == item.postedAt) item else item.copy(postedAt = at)
    }

/**
 * The upload time to keep when a server's list names a file this phone holds.
 * This vault's own list says when the copy landed here, which is not the
 * photo's date: the file's modified time (stamped on copy-in, CopiedInDate)
 * stays the date, as on iOS. An outside server's earliest time still counts.
 */
internal fun listedUploaded(existing: BlossomMediaItem, listed: Long?, fromThisVault: Boolean): Long? =
    if (fromThisVault) existing.uploaded else oldestUploaded(existing.uploaded, listed)

