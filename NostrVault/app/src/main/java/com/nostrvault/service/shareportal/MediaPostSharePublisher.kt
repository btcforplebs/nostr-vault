package com.nostrvault.service.shareportal

import android.content.Context
import android.graphics.BitmapFactory
import android.media.MediaMetadataRetriever
import androidx.exifinterface.media.ExifInterface
import com.nostrvault.data.model.PostingAccount
import com.nostrvault.service.BlossomService
import com.nostrvault.service.MediaPrivacy
import com.nostrvault.data.model.MediaUploadOutcomeMessage
import com.nostrvault.service.NostrService
import com.nostrvault.service.shareportal.handlers.MediaPostShareTags
import dagger.hilt.android.qualifiers.ApplicationContext
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import java.io.File
import javax.inject.Inject
import javax.inject.Singleton

/**
 * Uploads a shared picture/video post's files to the outside media servers
 * and publishes it (NIP-68 kind 20, NIP-71 kind 21/22; see
 * [MediaPostShareTags]). Every file is a temp copy: pictures readers can't
 * show become JPEGs, the location comes out, then it uploads signed by the
 * account it posts as. Twin: MediaPostShareHandler.swift.
 */
@Singleton
class MediaPostSharePublisher @Inject constructor(
    @ApplicationContext private val context: Context,
    private val nostrService: NostrService,
    private val blossomService: BlossomService,
) {
    class PublishException(message: String) : Exception(message)

    /** One shared file: its claimed copy and type. */
    data class Shared(val file: File, val mime: String)

    /** Uploads and publishes; throws [PublishException] with a message for the card. */
    suspend fun publish(
        files: List<Shared>,
        title: String,
        caption: String,
        lock: PostingAccount.Lock,
        onStatus: (String) -> Unit,
    ) {
        val shape = MediaPostShareTags.shape(files.map { it.mime })
        shape.problem?.let { throw PublishException(it.message) }
        val media = mutableListOf<MediaPostShareTags.Media>()
        for ((i, f) in files.withIndex()) {
            onStatus(if (files.size == 1) "Uploading…" else "Uploading ${i + 1} of ${files.size}…")
            media += withContext(Dispatchers.IO) { upload(f, lock) }
        }
        onStatus("Publishing…")
        val kind = MediaPostShareTags.kind(shape.shape!!, media)
        val tags = MediaPostShareTags.tags(shape.shape, media, title, caption, System.currentTimeMillis() / 1000)
        val content = MediaPostShareTags.content(caption)
        val event = try {
            // Literal kinds: UserListSignGuardTest flags a signer whose kind is a variable.
            when (kind) {
                20 -> nostrService.signEventAsync(kind = 20, content = content, tags = tags, lockedTo = lock)
                21 -> nostrService.signEventAsync(kind = 21, content = content, tags = tags, lockedTo = lock)
                else -> nostrService.signEventAsync(kind = 22, content = content, tags = tags, lockedTo = lock)
            }?.also { nostrService.requireStillPostingAs(lock, it.pubkey) }
        } catch (e: CancellationException) {
            throw e
        } catch (e: PostingAccount.AccountChangedException) {
            throw PublishException("The account changed while this was posting, so it was not sent. Switch back and post again.")
        } catch (e: Exception) {
            null
        } ?: throw PublishException("Couldn't sign the post. Check your key or signer in Settings.")
        nostrService.postEvent(event)
    }

    private suspend fun upload(shared: Shared, lock: PostingAccount.Lock): MediaPostShareTags.Media {
        val dir = File(context.cacheDir, "share-media").apply { mkdirs() }
        val ext = shared.file.extension.ifEmpty { "bin" }
        var mime = shared.mime.lowercase()
        var temp = File(dir, "${System.nanoTime()}.$ext")
        try {
            shared.file.copyTo(temp, overwrite = true)
            if (MediaPostShareTags.needsJpeg(mime)) {
                val jpeg = File(dir, "${System.nanoTime()}.jpg")
                if (!toJpeg(temp, jpeg)) {
                    jpeg.delete()
                    throw PublishException("Couldn't turn this picture into a JPEG, so it wasn't posted.")
                }
                temp.delete()
                temp = jpeg
                mime = "image/jpeg"
            }
            if (!MediaPrivacy.removeLocation(temp, mime)) throw PublishException(MediaPrivacy.FAILURE_MESSAGE)
            val sha = blossomService.computeSHA256(temp)
            val (w, h, duration) = measure(temp, mime)
            val url = when (val outcome = blossomService.uploadForPost(fileURL = temp, sha256 = sha, contentType = mime, signAs = lock)) {
                is BlossomService.PostUploadOutcome.Hosted -> outcome.url
                is BlossomService.PostUploadOutcome.SavedOnDevice ->
                    throw PublishException("No outside media server took the upload. Try again when one is reachable.")
                BlossomService.PostUploadOutcome.NoOutsideServer -> throw PublishException(MediaUploadOutcomeMessage.NO_OUTSIDE_SERVER)
                BlossomService.PostUploadOutcome.NotSavedOnDevice -> throw PublishException(MediaUploadOutcomeMessage.NOT_SAVED_ON_DEVICE)
            }
            return MediaPostShareTags.Media(url = url, mime = mime, sha256 = sha, width = w, height = h,
                bytes = temp.length(), duration = duration)
        } finally {
            temp.delete()
        }
    }

    /** Decodes any picture Android can read and writes it as a JPEG, upright. */
    private fun toJpeg(source: File, out: File): Boolean = runCatching {
        val bitmap = BitmapFactory.decodeFile(source.absolutePath) ?: return false
        val rotation = runCatching { ExifInterface(source.absolutePath).rotationDegrees }.getOrDefault(0)
        val upright = if (rotation == 0) bitmap else {
            val m = android.graphics.Matrix().apply { postRotate(rotation.toFloat()) }
            android.graphics.Bitmap.createBitmap(bitmap, 0, 0, bitmap.width, bitmap.height, m, true)
        }
        out.outputStream().use { upright.compress(android.graphics.Bitmap.CompressFormat.JPEG, 92, it) }
    }.getOrDefault(false)

    /** Width and height as shown (rotation applied), and seconds for a video. */
    private fun measure(file: File, mime: String): Triple<Int?, Int?, Double?> = runCatching {
        if (MediaPostShareTags.isVideo(mime)) {
            val r = MediaMetadataRetriever()
            try {
                r.setDataSource(file.absolutePath)
                val w = r.extractMetadata(MediaMetadataRetriever.METADATA_KEY_VIDEO_WIDTH)?.toIntOrNull()
                val h = r.extractMetadata(MediaMetadataRetriever.METADATA_KEY_VIDEO_HEIGHT)?.toIntOrNull()
                val rot = r.extractMetadata(MediaMetadataRetriever.METADATA_KEY_VIDEO_ROTATION)?.toIntOrNull() ?: 0
                val ms = r.extractMetadata(MediaMetadataRetriever.METADATA_KEY_DURATION)?.toLongOrNull()
                val (sw, sh) = if (rot == 90 || rot == 270) h to w else w to h
                Triple(sw, sh, ms?.let { it / 1000.0 })
            } finally {
                r.release()
            }
        } else {
            val o = BitmapFactory.Options().apply { inJustDecodeBounds = true }
            BitmapFactory.decodeFile(file.absolutePath, o)
            val rot = runCatching { ExifInterface(file.absolutePath).rotationDegrees }.getOrDefault(0)
            val w = o.outWidth.takeIf { it > 0 }
            val h = o.outHeight.takeIf { it > 0 }
            if (rot == 90 || rot == 270) Triple(h, w, null) else Triple(w, h, null)
        }
    }.getOrDefault(Triple(null, null, null))
}
