package com.nostrvault.service

import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.drawable.BitmapDrawable
import android.media.MediaMetadataRetriever
import android.net.Uri
import android.os.Build
import coil.ImageLoader
import coil.decode.DataSource
import coil.fetch.DrawableResult
import coil.fetch.FetchResult
import coil.fetch.Fetcher
import coil.request.Options
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.sync.Semaphore
import kotlinx.coroutines.sync.withPermit
import kotlinx.coroutines.withContext
import java.io.File
import java.io.IOException

/**
 * A Media tile's video, which the gallery already knows is a video. Vault blobs
 * are named by their sha256 with no extension, so Coil saw a file of unknown
 * type, never ran [coil.decode.VideoFrameDecoder], and the tile stayed black
 * (Media perf review 2026-11-28, finding 4). A remote blossom URL with no
 * ".mp4" skipped [RemoteVideoFrameFetcher] the same way.
 */
data class VaultVideoFrame(val sha256: String, val file: File?, val url: String)

/**
 * One frame per video, read once: a local blob through MediaMetadataRetriever
 * on IO, saved as `<sha256>.jpg` in [framesDirFor] (a `video_frames` folder
 * beside the blob folder, so it goes with the account's data) and read from
 * there on every later scroll and launch. A remote one goes through [RemoteVideoFrameFetcher],
 * which streams only the header and keeps its frame in Coil's disk cache.
 */
class VaultVideoFrameFetcher(
    private val data: VaultVideoFrame,
    private val options: Options,
    private val imageLoader: ImageLoader,
) : Fetcher {

    override suspend fun fetch(): FetchResult {
        val file = data.file
        if (file == null || !file.isFile) {
            return RemoteVideoFrameFetcher(data.url, options, imageLoader.diskCache).fetch()
        }
        val cached = frameFile(framesDirFor(file), data.sha256)
        val bitmap = withContext(Dispatchers.IO) {
            readSaved(cached) ?: permits.withPermit {
                // A second tile for the same sha may have saved it meanwhile.
                readSaved(cached) ?: grabFrame(file)?.also { save(it, cached) }
            }
        } ?: throw IOException("No frame for ${data.sha256}")
        return DrawableResult(
            drawable = BitmapDrawable(options.context.resources, bitmap),
            isSampled = true,
            dataSource = DataSource.DISK,
        )
    }

    class Factory : Fetcher.Factory<VaultVideoFrame> {
        override fun create(data: VaultVideoFrame, options: Options, imageLoader: ImageLoader): Fetcher =
            VaultVideoFrameFetcher(data, options, imageLoader)
    }

    companion object {
        /** Long side of a saved frame: tiles ask for 360, the list row less. */
        internal const val MAX_SIDE = 480
        private const val MAX_CONCURRENT = 2
        private val permits = Semaphore(MAX_CONCURRENT)

        /** `video_frames` next to the folder that holds [blob]; never inside it, where the relay lists blobs. */
        fun framesDirFor(blob: File): File =
            File(blob.absoluteFile.parentFile?.parentFile ?: blob.absoluteFile.parentFile, "video_frames")

        /** Drops [sha256]'s saved frame when its blob leaves [blobDir]. */
        fun forget(blobDir: File, sha256: String) {
            frameFile(framesDirFor(File(blobDir, sha256)), sha256)?.delete()
        }

        /** Where [sha256]'s frame is kept; null for anything that isn't a sha (no paths out of [dir]). */
        internal fun frameFile(dir: File, sha256: String): File? =
            sha256.lowercase().takeIf { it.length == 64 && it.all { c -> c in '0'..'9' || c in 'a'..'f' } }
                ?.let { File(dir, "$it.jpg") }

        private fun readSaved(file: File?): Bitmap? =
            file?.takeIf { it.isFile && it.length() > 0 }?.let { BitmapFactory.decodeFile(it.path) }

        private fun save(bitmap: Bitmap, file: File?) {
            file ?: return
            runCatching {
                file.parentFile?.mkdirs()
                val tmp = File(file.parentFile, file.name + ".tmp")
                tmp.outputStream().use { bitmap.compress(Bitmap.CompressFormat.JPEG, 85, it) }
                if (!tmp.renameTo(file)) tmp.delete()
            }
        }

        /** One frame, at most [MAX_SIDE] on its long side; never a full-size 4K decode. */
        private fun grabFrame(file: File): Bitmap? {
            val retriever = MediaMetadataRetriever()
            return try {
                retriever.setDataSource(file.path)
                if (Build.VERSION.SDK_INT >= 27) {
                    retriever.getScaledFrameAtTime(0, MediaMetadataRetriever.OPTION_CLOSEST_SYNC, MAX_SIDE, MAX_SIDE)
                } else {
                    val w = retriever.extractMetadata(MediaMetadataRetriever.METADATA_KEY_VIDEO_WIDTH)?.toIntOrNull() ?: 0
                    val h = retriever.extractMetadata(MediaMetadataRetriever.METADATA_KEY_VIDEO_HEIGHT)?.toIntOrNull() ?: 0
                    if (w <= 0 || h <= 0 || w.toLong() * h > 1920L * 1080L) return null
                    val full = retriever.getFrameAtTime(0, MediaMetadataRetriever.OPTION_CLOSEST_SYNC) ?: return null
                    val scale = minOf(1f, MAX_SIDE.toFloat() / maxOf(full.width, full.height))
                    if (scale >= 1f) full
                    else Bitmap.createScaledBitmap(full, (full.width * scale).toInt(), (full.height * scale).toInt(), true)
                        .also { if (it !== full) full.recycle() }
                }
            } catch (e: Exception) {
                null
            } finally {
                runCatching { retriever.release() }
            }
        }

        /** What a Media tile asks Coil for: its frame when it is a video, else the file or URL. */
        fun tileData(sha256: String, isVideo: Boolean, file: File?, url: String): Any = when {
            !isVideo -> file ?: url
            file == null && !(url.startsWith("http://") || url.startsWith("https://")) -> url
            else -> VaultVideoFrame(sha256, file, url)
        }
    }
}
