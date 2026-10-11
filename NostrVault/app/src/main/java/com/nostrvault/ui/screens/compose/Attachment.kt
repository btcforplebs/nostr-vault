package com.nostrvault.ui.screens

import android.net.Uri
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.items
import androidx.compose.material.icons.filled.*
import androidx.compose.material3.*
import androidx.compose.runtime.*
import com.nostrvault.ui.theme.*
import java.io.File

data class Attachment(
    val id: String = java.util.UUID.randomUUID().toString(),
    val uri: Uri,
    val mimeType: String,
    val isVideo: Boolean = false,
    var uploadedUrl: String? = null,
    var isUploading: Boolean = false,
    var uploadProgress: Float = 0f,
    /**
     * NIP-92 `alt` — what this media is, for anyone who cannot see it.
     * Published inside the attachment's `imeta` tag; blank means omitted.
     */
    val altText: String = "",
    /**
     * Set when the media is already on a Blossom server (picked from the
     * relay picker): posting publishes this URL as-is instead of uploading.
     */
    val hostedUrl: String? = null,
    /** The hosted blob's hash, for its `imeta x`. */
    val sha256: String? = null,
    /** A local copy of the hosted blob, measured for `imeta dim`. */
    val localFile: File? = null,
    /** The hosted blob's size, for `imeta size`. */
    val byteCount: Long? = null,
)

/**
 * A full MIME type for a blob, from the server's `type` when that is one,
 * else from the file extension; null when neither says. Local blobs are only
 * classed as "image"/"video", which is not a MIME type and must not reach
 * `imeta m`.
 */
internal fun blobMimeType(serverType: String?, name: String?): String? {
    if (serverType != null && '/' in serverType && !serverType.endsWith("/*")) return serverType
    return when (name?.substringBefore('?')?.substringAfterLast('.', "")?.lowercase()) {
        "jpg", "jpeg" -> "image/jpeg"
        "png" -> "image/png"
        "gif" -> "image/gif"
        "webp" -> "image/webp"
        "avif" -> "image/avif"
        "mp4", "m4v" -> "video/mp4"
        "mov" -> "video/quicktime"
        "webm" -> "video/webm"
        "mp3" -> "audio/mpeg"
        "m4a" -> "audio/mp4"
        "aac" -> "audio/aac"
        "wav" -> "audio/wav"
        "ogg" -> "audio/ogg"
        "opus" -> "audio/opus"
        "flac" -> "audio/flac"
        else -> null
    }
}

/**
 * How many attachments one note carries. The editor's row, the upload progress
 * copy and every reader's media layout assume a small number.
 */
const val MAX_ATTACHMENTS = 4

/**
 * What to ask `PickMultipleVisualMedia` for when [attachmentCount] are already
 * attached.
 *
 * The contract rejects `maxItems <= 1` at construction ("Max items must be
 * higher than 1") and the composable rebuilds it on every recomposition, so
 * handing it the literal number of free slots threw as soon as only one was
 * left. Two is the floor; [ComposeNoteViewModel.addAttachments] discards
 * anything over the real cap.
 */
internal fun pickerMaxItems(attachmentCount: Int): Int =
    maxOf(2, MAX_ATTACHMENTS - attachmentCount)
