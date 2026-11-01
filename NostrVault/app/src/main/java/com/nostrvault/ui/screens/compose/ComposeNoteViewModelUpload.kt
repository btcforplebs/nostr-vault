package com.nostrvault.ui.screens

import android.graphics.BitmapFactory
import android.media.MediaMetadataRetriever
import android.util.Log
import androidx.compose.foundation.layout.*
import androidx.compose.material.icons.filled.*
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.draw.clip
import androidx.lifecycle.viewModelScope
import com.nostrvault.data.model.MediaUploadOutcomeMessage
import com.nostrvault.data.model.QueuedMediaPost
import com.nostrvault.service.BlossomService
import com.nostrvault.service.MediaPrivacy
import com.nostrvault.ui.theme.*
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import java.io.File

    /** Media picked from the relay: already hosted, so published with its URL as-is. */
    internal fun ComposeNoteViewModel.hostedMedia(attachment: Attachment): QueuedMediaPost.Media {
        val pixelSize = attachment.localFile?.takeIf { it.exists() }?.let { pixelSize(it, attachment.isVideo) }
        return QueuedMediaPost.Media(
            sha256 = attachment.sha256,
            mimeType = attachment.mimeType.takeUnless { it.endsWith("/*") },
            url = attachment.hostedUrl,
            pixelWidth = pixelSize?.first,
            pixelHeight = pixelSize?.second,
            alt = attachment.altText,
            byteCount = attachment.byteCount,
        )
    }

    /**
     * Uploads one attachment: what the old per-post loop did for each item,
     * now run by [ComposeNoteUploads] the moment the photo is picked. Same
     * preferred hosts, same location stripping, same on-device fallback.
     * [skipOutside] is set once an earlier upload found every outside server
     * down, so this one is saved here only rather than waiting out the retry.
     */
    internal suspend fun ComposeNoteViewModel.uploadOne(
        attachment: Attachment,
        skipOutside: Boolean,
        onProgress: (Float) -> Unit,
    ): ComposeNoteUpload = withContext(Dispatchers.IO) {
        val notSaved = ComposeNoteUpload.Failed(MediaUploadOutcomeMessage.NOT_SAVED_ON_DEVICE)
        var tempFile: File? = null
        try {
            // Read file from URI
            val inputStream = context.contentResolver.openInputStream(attachment.uri)
                ?: return@withContext notSaved

            var file = File.createTempFile("upload_", ".tmp", context.cacheDir)
            tempFile = file
            file.outputStream().use { output ->
                inputStream.use { input ->
                    input.copyTo(output)
                }
            }

            // HEIC becomes JPEG (the re-encode also drops its location);
            // anything else keeps its bytes.
            var mimeType = attachment.mimeType
            if (isHeic(mimeType)) {
                val jpeg = File.createTempFile("upload_", ".jpg", context.cacheDir)
                if (convertHeicToJpeg(file, jpeg)) {
                    file.delete()
                    file = jpeg
                    tempFile = jpeg
                    mimeType = JPEG_MIME
                } else {
                    jpeg.delete()
                }
            }

            // The location comes out before the hash: the blob is public
            // once uploaded (iOS #335).
            if (!MediaPrivacy.removeLocation(file, mimeType)) {
                return@withContext ComposeNoteUpload.Failed(MediaPrivacy.FAILURE_MESSAGE)
            }

            // Compute SHA-256
            val sha256 = blossomService.computeSHA256(file)

            // Measured from the file on disk, before it is deleted below.
            val pixelSize = pixelSize(file, attachment.isVideo)
            val byteCount = file.length()

            val outcome = blossomService.uploadForPost(
                fileURL = file,
                sha256 = sha256,
                contentType = mimeType,
                skipOutsideServers = skipOutside,
                onProgress = onProgress,
            )

            var unreachable = emptyList<String>()
            val url = when (outcome) {
                is BlossomService.PostUploadOutcome.Hosted -> outcome.url
                is BlossomService.PostUploadOutcome.SavedOnDevice -> {
                    // Safe on this device; the post will wait for a server.
                    unreachable = outcome.unreachable
                    null
                }
                BlossomService.PostUploadOutcome.NoOutsideServer ->
                    return@withContext ComposeNoteUpload.Failed(MediaUploadOutcomeMessage.NO_OUTSIDE_SERVER)
                BlossomService.PostUploadOutcome.NotSavedOnDevice ->
                    return@withContext notSaved
            }

            ComposeNoteUpload.Done(
                QueuedMediaPost.Media(
                    sha256 = sha256,
                    mimeType = mimeType,
                    url = url,
                    pixelWidth = pixelSize?.first,
                    pixelHeight = pixelSize?.second,
                    alt = attachment.altText,
                    byteCount = byteCount,
                ),
                unreachable,
            )
        } catch (e: kotlinx.coroutines.CancellationException) {
            throw e
        } catch (e: Exception) {
            Log.e("ComposeNote", "Upload failed", e)
            notSaved
        } finally {
            // Removing the photo mid-upload cancels this; the copy goes either way.
            tempFile?.delete()
        }
    }

    /** Host of a server URL, for naming it in a message. */
    internal fun ComposeNoteViewModel.hostOf(url: String): String? =
        runCatching { java.net.URI(url).host }.getOrNull()?.takeIf { it.isNotEmpty() }

    /**
     * Pixel dimensions of a local media file, as `width to height`.
     *
     * Images are measured from the header alone (`inJustDecodeBounds`) — an
     * `imeta dim` is worth one header read, not a full decode of a 12-megapixel
     * photo. Videos report the track's rotation separately from its width and
     * height, so a portrait clip shot on a phone measures landscape unless the
     * rotation is applied; getting that backwards would reserve a sideways box
     * in every client that trusts our `dim`.
     */
    private fun ComposeNoteViewModel.pixelSize(file: File, isVideo: Boolean): Pair<Int, Int>? = try {
        if (isVideo) {
            // MediaMetadataRetriever only became AutoCloseable at API 29 and
            // this app runs from 26, so it is released by hand.
            val retriever = MediaMetadataRetriever()
            try {
                retriever.setDataSource(file.absolutePath)
                val w = retriever.extractMetadata(MediaMetadataRetriever.METADATA_KEY_VIDEO_WIDTH)?.toIntOrNull()
                val h = retriever.extractMetadata(MediaMetadataRetriever.METADATA_KEY_VIDEO_HEIGHT)?.toIntOrNull()
                val rotation = retriever.extractMetadata(MediaMetadataRetriever.METADATA_KEY_VIDEO_ROTATION)?.toIntOrNull() ?: 0
                if (w == null || h == null || w <= 0 || h <= 0) null
                else if (rotation == 90 || rotation == 270) h to w
                else w to h
            } finally {
                retriever.release()
            }
        } else {
            val options = BitmapFactory.Options().apply { inJustDecodeBounds = true }
            BitmapFactory.decodeFile(file.absolutePath, options)
            if (options.outWidth > 0 && options.outHeight > 0) options.outWidth to options.outHeight else null
        }
    } catch (e: Exception) {
        // A note without `dim` still publishes; it just makes readers measure.
        Log.w("ComposeNote", "Could not measure media dimensions", e)
        null
    }
