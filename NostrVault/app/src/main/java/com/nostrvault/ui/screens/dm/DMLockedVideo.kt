package com.nostrvault.ui.screens.dm

import android.content.Context
import android.media.MediaMetadataRetriever
import android.net.Uri
import android.util.Log
import androidx.annotation.OptIn
import androidx.media3.common.MediaItem
import androidx.media3.common.MimeTypes
import androidx.media3.common.util.UnstableApi
import androidx.media3.effect.Presentation
import androidx.media3.transformer.Composition
import androidx.media3.transformer.DefaultEncoderFactory
import androidx.media3.transformer.EditedMediaItem
import androidx.media3.transformer.EditedMediaItemSequence
import androidx.media3.transformer.Effects
import androidx.media3.transformer.ExportException
import androidx.media3.transformer.ExportResult
import androidx.media3.transformer.Transformer
import androidx.media3.transformer.VideoEncoderSettings
import com.nostrvault.service.BlossomService
import com.nostrvault.service.DMFile
import com.nostrvault.service.MediaPrivacy
import com.nostrvault.service.uploadLocked
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.suspendCancellableCoroutine
import kotlinx.coroutines.withContext
import java.io.File
import kotlin.coroutines.resume

/**
 * A video for a NIP-17 DM, locked like a photo ([DMLockedPhoto], kind 15; Logen 2026-11-15):
 * compressed to at most 1080p H.264/AAC (the size the iOS feed's diVine export uses,
 * AVAssetExportPreset1920x1080), its location taken out, refused over [DMFile.MAX_FILE], encrypted
 * with a fresh key, and the ciphertext uploaded as it is.
 */
@OptIn(UnstableApi::class)
object DMLockedVideo {
    const val TOO_BIG = "That video is too big to send, even compressed (at most 100 MB). Try a shorter clip."
    const val UNREADABLE = "Couldn't read that video."

    /** The compressed picture: its short side at most this (1080p). */
    private const val SHORT_SIDE = 1080

    /** Video bitrate after compressing, at most: about 2.5 minutes fits in [DMFile.MAX_FILE]. */
    internal const val VIDEO_BITRATE = 5_000_000

    private const val TAG = "DMLockedVideo"

    /** The message for a compressed video of [bytes], null when it may be sent. Encrypting adds 16 bytes. */
    fun sizeError(bytes: Long): String? = if (bytes + 16 > DMFile.MAX_FILE) TOO_BIG else null

    /**
     * Throws [DMLockedPhoto.Unsendable] for a video that can't be read or is too big after compressing,
     * [DMPhotoUploadException] when no server took it.
     */
    suspend fun prepare(context: Context, uri: Uri, blossom: BlossomService): DMFile.Message {
        val file = compressed(context, uri)
        try {
            sizeError(file.length())?.let { throw DMLockedPhoto.Unsendable(it) }
            val enc = encryptFile(file)
            val url = blossom.uploadLocked(enc.cipher, enc.x) ?: throw DMPhotoUploadException()
            return DMFile.fileMessage(url, enc, "video/mp4")
        } finally {
            file.delete()
        }
    }

    /** Read and encrypt [file], then delete it; the plain bytes are let go before the upload. */
    private suspend fun encryptFile(file: File): DMFile.Encrypted = withContext(Dispatchers.Default) {
        val plain = file.readBytes()
        file.delete()
        DMFile.encrypt(plain)
    }

    /**
     * The video as an MP4 to lock: compressed, or (when this phone can't compress it) as it is.
     * Either way it has no location. A clip that can't fit even compressed is refused before any
     * work (its length at the bitrate it will get).
     */
    private suspend fun compressed(context: Context, uri: Uri): File {
        val (durationMs, sourceBitrate) = withContext(Dispatchers.IO) { probe(context, uri) }
        // Never more than the clip already has: a small clip must not grow.
        val bitrate = if (sourceBitrate in 1 until VIDEO_BITRATE) sourceBitrate else VIDEO_BITRATE
        if (durationMs > 0 && durationMs / 1000.0 * (bitrate + 128_000) / 8 > DMFile.MAX_FILE) {
            throw DMLockedPhoto.Unsendable(TOO_BIG)
        }
        val out = withContext(Dispatchers.IO) { File.createTempFile("dm_video_", ".mp4", context.cacheDir) }
        val ok = try {
            export(context, uri, out, bitrate)
        } catch (e: kotlinx.coroutines.CancellationException) {
            out.delete()
            throw e
        } catch (e: Exception) {
            Log.w(TAG, "compress failed, sending as it is: ${e.message}")
            false
        }
        return withContext(Dispatchers.IO) {
            if (!ok) {
                // As it is (a codec this phone can't re-encode): copied and capped.
                val copied = try {
                    context.contentResolver.openInputStream(uri)?.use { copyCapped(it, out) }
                } catch (e: java.io.IOException) {
                    null
                }
                if (copied == null) { out.delete(); throw DMLockedPhoto.Unsendable(UNREADABLE) }
                if (sizeError(copied) != null) { out.delete(); throw DMLockedPhoto.Unsendable(TOO_BIG) }
            }
            // An export can carry the source's location over; the feed's remux takes it out.
            if (!MediaPrivacy.removeLocation(out, "video/mp4")) {
                out.delete()
                throw DMLockedPhoto.Unsendable(UNREADABLE)
            }
            out
        }
    }

    private fun probe(context: Context, uri: Uri): Pair<Long, Int> {
        val r = MediaMetadataRetriever()
        return try {
            r.setDataSource(context, uri)
            val d = r.extractMetadata(MediaMetadataRetriever.METADATA_KEY_DURATION)?.toLongOrNull() ?: 0L
            val b = r.extractMetadata(MediaMetadataRetriever.METADATA_KEY_BITRATE)?.toIntOrNull() ?: 0
            d to b
        } catch (e: Exception) {
            throw DMLockedPhoto.Unsendable(UNREADABLE)
        } finally {
            runCatching { r.release() }
        }
    }

    /** Re-encodes [uri] into [out] (H.264 + AAC, short side at most 1080, HDR toned to SDR); true when done. */
    private suspend fun export(context: Context, uri: Uri, out: File, bitrate: Int): Boolean =
        withContext(Dispatchers.Main) {
            suspendCancellableCoroutine { cont ->
                val app = context.applicationContext
                val encoders = DefaultEncoderFactory.Builder(app)
                    .setRequestedVideoEncoderSettings(VideoEncoderSettings.Builder().setBitrate(bitrate).build())
                    .setEnableFallback(true)
                    .build()
                val transformer = Transformer.Builder(app)
                    .setVideoMimeType(MimeTypes.VIDEO_H264)
                    .setAudioMimeType(MimeTypes.AUDIO_AAC)
                    .setEncoderFactory(encoders)
                    .addListener(object : Transformer.Listener {
                        override fun onCompleted(composition: Composition, exportResult: ExportResult) {
                            if (cont.isActive) cont.resume(true)
                        }

                        override fun onError(composition: Composition, exportResult: ExportResult, exportException: ExportException) {
                            Log.w(TAG, "export: ${exportException.errorCodeName}: ${exportException.message}")
                            if (cont.isActive) cont.resume(false)
                        }
                    })
                    .build()
                val item = EditedMediaItem.Builder(MediaItem.fromUri(uri))
                    .setEffects(Effects(emptyList(), listOf(Presentation.createForShortSide(SHORT_SIDE))))
                    .build()
                val composition = Composition.Builder(EditedMediaItemSequence.Builder(item).build())
                    .setHdrMode(Composition.HDR_MODE_TONE_MAP_HDR_TO_SDR_USING_OPEN_GL)
                    .build()
                transformer.start(composition, out.absolutePath)
                // The transformer is the main thread's; a cancel may come from any thread.
                cont.invokeOnCancellation { android.os.Handler(android.os.Looper.getMainLooper()).post { transformer.cancel() } }
            }
        }

    /** Copies at most [DMFile.MAX_FILE] + 1 bytes: the size, or more than the cap when it was bigger. */
    private fun copyCapped(input: java.io.InputStream, to: File): Long {
        var total = 0L
        to.outputStream().use { o ->
            val buf = ByteArray(64 * 1024)
            while (true) {
                val n = input.read(buf)
                if (n < 0) break
                total += n
                if (total > DMFile.MAX_FILE) return total
                o.write(buf, 0, n)
            }
        }
        return total
    }
}
