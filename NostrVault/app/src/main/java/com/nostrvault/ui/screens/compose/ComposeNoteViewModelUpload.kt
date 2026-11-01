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
import kotlinx.coroutines.async
import kotlinx.coroutines.awaitAll
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

            // Whether this photo was already out there (an earlier post from
            // this or another device): only a blob every server the delete
            // would reach clearly lacks may be deleted if the photo is dropped.
            val preExisting = alreadyOutThere(sha256)

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
                preExisting = preExisting,
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

    /**
     * True unless the owner's vault and every server a delete would reach
     * (the mirrors and the published server list) each clearly answer 404 for
     * [sha256]. A blob posted before, from any device, is then never deleted
     * when this photo is dropped. No answer, an error, or any 2xx counts as there.
     */
    private suspend fun ComposeNoteViewModel.alreadyOutThere(sha256: String): Boolean = kotlinx.coroutines.coroutineScope {
        val base = blossomService.localBlossomURL() ?: return@coroutineScope true
        val published = nostrService.serverLists.value[nostrService.ownerHexPubkey].orEmpty()
        val outside = configStore.config.value.blossomDeleteTargets(published, null, includeHomeVault = false)
        val checks = listOf(base to blossomService.localClient) + outside.map { it to blossomService.remoteClient }
        checks.map { (server, client) ->
            async { !answers404(client, "${server.trimEnd('/')}/$sha256") }
        }.awaitAll().any { it }
    }

    private fun answers404(client: okhttp3.OkHttpClient, url: String): Boolean = try {
        val request = okhttp3.Request.Builder().url(url).head().build()
        client.newCall(request).execute().use { it.code == 404 }
    } catch (e: Exception) {
        false
    }

    /**
     * Best-effort delete of blobs this composer uploaded that nothing will
     * use (a photo removed, or the composer closed unsent), so a photo picked
     * and dropped does not stay public on the outside servers. The owner's
     * vault keeps its copy. Runs on [scope], which outlives the screen.
     */
    internal fun ComposeNoteViewModel.deleteUnused(media: List<QueuedMediaPost.Media>, scope: kotlinx.coroutines.CoroutineScope) {
        media.forEach { item ->
            val sha = item.sha256 ?: return@forEach
            scope.launch {
                // No photo URL: only the servers alreadyOutThere asked, so the
                // set deleted from is exactly the set checked before the upload.
                runCatching { blossomService.deleteFromServers(sha, null, includeHomeVault = false) }
                    .onFailure { Log.w("ComposeNote", "Could not delete a dropped upload", it) }
            }
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
