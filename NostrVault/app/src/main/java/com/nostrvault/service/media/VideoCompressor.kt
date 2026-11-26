package com.nostrvault.service.media

import android.content.Context
import android.media.MediaExtractor
import android.media.MediaFormat
import android.media.MediaMetadataRetriever
import android.net.Uri
import android.os.Handler
import android.os.Looper
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
import androidx.media3.transformer.ProgressHolder
import androidx.media3.transformer.Transformer
import androidx.media3.transformer.VideoEncoderSettings
import com.nostrvault.ui.screens.dm.DMLockedPhoto
import com.nostrvault.ui.screens.dm.DMLockedVideo.UNREADABLE
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.suspendCancellableCoroutine
import kotlinx.coroutines.withContext
import java.io.File
import kotlin.coroutines.resume

/**
 * Shrinks a video before it is uploaded (RESEARCH NV_UPLOAD_COMPRESSION §4.1, plan D3; Logen
 * 2026-11-26: 720p long edge, 5 Mbps, AAC): H.264 + AAC in MP4, the long edge at most
 * [LONG_EDGE], video at most [VIDEO_BITRATE] and never above the clip's own, HDR toned to SDR.
 *
 * - A clip already small ([plan]: H.264, long edge ≤ [LONG_EDGE], ≤ [KEEP_BITRATE]) keeps its bytes.
 * - [ImageCompressor.Quality.ORIGINAL] keeps every byte (the Media tab).
 * - When this phone can't re-encode it, or the result isn't smaller, the source comes back.
 *
 * Location: callers still run [com.nostrvault.service.MediaPrivacy.removeLocation] on what
 * [compress] returns, for every quality, as the last step.
 *
 * DM videos ([DMLockedVideo]) keep their own size (short side 1080) through [export].
 * Apple twin: `Services/MediaCompression/VideoCompressor.swift` (plan A3).
 */
@OptIn(UnstableApi::class)
object VideoCompressor {
    /** Feed/share videos: the long edge at most this (720p). */
    const val LONG_EDGE = 720

    /** Video bitrate after compressing, at most. */
    const val VIDEO_BITRATE = 5_000_000

    /** A clip already H.264 and small at or under this bitrate goes up as it is. */
    const val KEEP_BITRATE = 6_000_000

    const val MP4 = "video/mp4"

    /** The DM picture: its short side at most this (1080p). */
    private const val SHORT_SIDE = 1080

    private const val TAG = "VideoCompressor"
    private const val PROGRESS_EVERY_MS = 250L

    /** The file to upload and its type. [file] is the source itself when nothing was changed. */
    data class Output(val file: File, val mimeType: String)

    /** What the clip is, as far as [plan] needs to know. Zero when unknown. */
    data class Source(
        val width: Int,
        val height: Int,
        /** Whole-file bitrate, bits per second. */
        val bitrate: Int,
        /** The video track's codec, e.g. `video/avc`; null when unknown. */
        val videoMime: String?,
    )

    sealed class Plan {
        /** Upload the bytes as they are. */
        object Keep : Plan()
        /** Re-encode at [bitrate]; [shortSide] scales the picture down, null keeps its size. */
        data class Encode(val shortSide: Int?, val bitrate: Int) : Plan()
    }

    /** What to do with [source] at [quality]. */
    fun plan(source: Source, quality: ImageCompressor.Quality): Plan {
        if (quality == ImageCompressor.Quality.ORIGINAL) return Plan.Keep
        val long = maxOf(source.width, source.height)
        val short = minOf(source.width, source.height)
        if (source.videoMime == MimeTypes.VIDEO_H264 && long in 1..LONG_EDGE && source.bitrate in 1..KEEP_BITRATE) {
            return Plan.Keep
        }
        // Never more than the clip already has: a small clip must not grow.
        val bitrate = if (source.bitrate in 1 until VIDEO_BITRATE) source.bitrate else VIDEO_BITRATE
        // Even sizes: encoders want them.
        val shortSide = if (long > LONG_EDGE && short > 0) maxOf(2, (short.toLong() * LONG_EDGE / long).toInt() and 1.inv()) else null
        return Plan.Encode(shortSide, bitrate)
    }

    /**
     * The video to upload from [source] (a temp copy the caller owns). Never throws but for a
     * cancel: anything that goes wrong gives [source] back, as uploads were before.
     * [onProgress] gets 0..1 while it re-encodes.
     */
    suspend fun compress(
        context: Context,
        source: File,
        mimeType: String,
        quality: ImageCompressor.Quality,
        workDir: File,
        onProgress: (Float) -> Unit = {},
    ): Output {
        val asIs = Output(source, mimeType)
        untouched(source, mimeType, quality)?.let { return it }
        val info = withContext(Dispatchers.IO) { describe(source) } ?: return asIs
        val plan = plan(info, quality) as? Plan.Encode ?: return asIs
        val out = withContext(Dispatchers.IO) { File.createTempFile("video_", ".mp4", workDir) }
        val ok = try {
            export(context, Uri.fromFile(source), out, plan.bitrate, plan.shortSide, onProgress)
        } catch (e: CancellationException) {
            out.delete()
            throw e
        } catch (e: Exception) {
            Log.w(TAG, "compress failed, sending as it is: ${e.message}")
            false
        }
        if (!ok || out.length() == 0L || out.length() >= source.length()) {
            out.delete()
            return asIs
        }
        Log.i(TAG, "compressed ${source.length()} -> ${out.length()} bytes (${info.width}x${info.height}, ${info.bitrate} bps)")
        return Output(out, MP4)
    }

    /**
     * [source] as it is, without opening it, when there is nothing to do: Original quality
     * (Settings > Media & Cache > Upload Quality, or the Media tab), or not a video. Null otherwise.
     */
    fun untouched(source: File, mimeType: String, quality: ImageCompressor.Quality): Output? =
        if (quality == ImageCompressor.Quality.ORIGINAL || !mimeType.lowercase().startsWith("video/")) Output(source, mimeType) else null

    /** [compress], deleting [source] when a new file replaced it. */
    suspend fun replacing(
        context: Context,
        source: File,
        mimeType: String,
        quality: ImageCompressor.Quality,
        workDir: File,
        onProgress: (Float) -> Unit = {},
    ): Output = compress(context, source, mimeType, quality, workDir, onProgress)
        .also { if (it.file != source) source.delete() }

    /** Size, bitrate and codec of [file]; null when it can't be read. */
    private fun describe(file: File): Source? {
        val r = MediaMetadataRetriever()
        val (w, h, b) = try {
            r.setDataSource(file.absolutePath)
            Triple(
                r.extractMetadata(MediaMetadataRetriever.METADATA_KEY_VIDEO_WIDTH)?.toIntOrNull() ?: 0,
                r.extractMetadata(MediaMetadataRetriever.METADATA_KEY_VIDEO_HEIGHT)?.toIntOrNull() ?: 0,
                r.extractMetadata(MediaMetadataRetriever.METADATA_KEY_BITRATE)?.toIntOrNull() ?: 0,
            )
        } catch (e: Exception) {
            return null
        } finally {
            runCatching { r.release() }
        }
        return Source(w, h, b, videoTrackMime(file))
    }

    private fun videoTrackMime(file: File): String? {
        val x = MediaExtractor()
        return try {
            x.setDataSource(file.absolutePath)
            (0 until x.trackCount).firstNotNullOfOrNull { i ->
                x.getTrackFormat(i).getString(MediaFormat.KEY_MIME)?.takeIf { it.startsWith("video/") }
            }
        } catch (e: Exception) {
            null
        } finally {
            runCatching { x.release() }
        }
    }

    fun probe(context: Context, uri: Uri): Pair<Long, Int> {
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

    /**
     * Re-encodes [uri] into [out] (H.264 + AAC, short side at most [shortSide] or kept when null,
     * HDR toned to SDR); true when done. [onProgress] gets 0..1 while it runs.
     */
    suspend fun export(
        context: Context,
        uri: Uri,
        out: File,
        bitrate: Int,
        shortSide: Int? = SHORT_SIDE,
        onProgress: ((Float) -> Unit)? = null,
    ): Boolean =
        withContext(Dispatchers.Main) {
            suspendCancellableCoroutine { cont ->
                val app = context.applicationContext
                val main = Handler(Looper.getMainLooper())
                val encoders = DefaultEncoderFactory.Builder(app)
                    .setRequestedVideoEncoderSettings(VideoEncoderSettings.Builder().setBitrate(bitrate).build())
                    .setEnableFallback(true)
                    .build()
                lateinit var poll: Runnable
                val transformer = Transformer.Builder(app)
                    .setVideoMimeType(MimeTypes.VIDEO_H264)
                    .setAudioMimeType(MimeTypes.AUDIO_AAC)
                    .setEncoderFactory(encoders)
                    .addListener(object : Transformer.Listener {
                        override fun onCompleted(composition: Composition, exportResult: ExportResult) {
                            main.removeCallbacks(poll)
                            onProgress?.invoke(1f)
                            if (cont.isActive) cont.resume(true)
                        }

                        override fun onError(composition: Composition, exportResult: ExportResult, exportException: ExportException) {
                            main.removeCallbacks(poll)
                            Log.w(TAG, "export: ${exportException.errorCodeName}: ${exportException.message}")
                            if (cont.isActive) cont.resume(false)
                        }
                    })
                    .build()
                val effects = shortSide?.let { listOf(Presentation.createForShortSide(it)) } ?: emptyList()
                val item = EditedMediaItem.Builder(MediaItem.fromUri(uri))
                    .setEffects(Effects(emptyList(), effects))
                    .build()
                val composition = Composition.Builder(EditedMediaItemSequence.Builder(item).build())
                    .setHdrMode(Composition.HDR_MODE_TONE_MAP_HDR_TO_SDR_USING_OPEN_GL)
                    .build()
                val holder = ProgressHolder()
                poll = Runnable {
                    if (transformer.getProgress(holder) == Transformer.PROGRESS_STATE_AVAILABLE) {
                        onProgress?.invoke(holder.progress / 100f)
                    }
                    if (cont.isActive) main.postDelayed(poll, PROGRESS_EVERY_MS)
                }
                transformer.start(composition, out.absolutePath)
                if (onProgress != null) main.postDelayed(poll, PROGRESS_EVERY_MS)
                // The transformer is the main thread's; a cancel may come from any thread.
                cont.invokeOnCancellation { main.post { main.removeCallbacks(poll); transformer.cancel() } }
            }
        }
}
