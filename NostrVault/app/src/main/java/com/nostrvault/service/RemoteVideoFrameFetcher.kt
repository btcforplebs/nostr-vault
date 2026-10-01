package com.nostrvault.service

import android.graphics.Bitmap
import android.graphics.drawable.BitmapDrawable
import android.media.MediaMetadataRetriever
import android.net.Uri
import android.os.Build
import coil.ImageLoader
import coil.decode.DataSource
import coil.decode.ImageSource
import coil.disk.DiskCache
import coil.fetch.DrawableResult
import coil.fetch.FetchResult
import coil.fetch.Fetcher
import coil.fetch.SourceResult
import coil.request.Options
import com.nostrvault.ui.components.isVideoUrl
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.async
import kotlinx.coroutines.isActive
import kotlinx.coroutines.sync.Semaphore
import kotlinx.coroutines.withTimeoutOrNull
import java.io.IOException

/**
 * The still frame shown for a remote video in the feed, read by streaming the
 * file's header instead of downloading all of it.
 *
 * Without this, Coil's HTTP fetcher downloads the *whole* video into the image
 * disk cache so `VideoFrameDecoder` can read one frame from it: tens of MB per
 * row, competing with every photo for the same connections, and cut off by the
 * 25 s call timeout on a slow link, so the video never got a frame at all.
 * `MediaMetadataRetriever` given the URL fetches only the byte ranges it needs,
 * which is what iOS's `AVAssetImageGenerator` does.
 *
 * At most [MAX_CONCURRENT] run at once (iOS: 2), so videos cannot take every
 * slot from photos. The frame is saved as a JPEG in Coil's disk cache, so it
 * is read once per URL, not once per scroll.
 */
class RemoteVideoFrameFetcher(
    private val url: String,
    private val options: Options,
    private val diskCache: DiskCache?,
) : Fetcher {

    override suspend fun fetch(): FetchResult {
        val key = DISK_KEY_PREFIX + url
        diskCache?.openSnapshot(key)?.let { snapshot ->
            return SourceResult(
                source = ImageSource(snapshot.data, diskCache.fileSystem, key, snapshot),
                mimeType = "image/jpeg",
                dataSource = DataSource.DISK,
            )
        }

        permits.acquire()
        val frame = try {
            // The retriever's network read is native and ignores cancellation;
            // run it apart so a dead host costs a slot for TIMEOUT_MS, not forever.
            // Reads left running past the timeout keep a [nativeReads] slot until
            // they end, so dead hosts cannot pile up unbounded native reads.
            if (!nativeReads.tryAcquire()) throw IOException("Too many stalled frame reads")
            val grab = retrievalScope.async {
                try { grabFrame(url) { isActive } } finally { nativeReads.release() }
            }
            withTimeoutOrNull(TIMEOUT_MS) { grab.await() } ?: run {
                grab.cancel()
                null
            }
        } finally {
            permits.release()
        } ?: throw IOException("No frame for $url")

        diskCache?.openEditor(key)?.let { editor ->
            try {
                diskCache.fileSystem.write(editor.data) {
                    frame.compress(Bitmap.CompressFormat.JPEG, 85, outputStream())
                }
                editor.commit()
            } catch (e: Exception) {
                editor.abort()
            }
        }
        return DrawableResult(
            drawable = BitmapDrawable(options.context.resources, frame),
            isSampled = true,
            dataSource = DataSource.NETWORK,
        )
    }

    class Factory : Fetcher.Factory<Uri> {
        override fun create(data: Uri, options: Options, imageLoader: ImageLoader): Fetcher? {
            if (data.scheme != "http" && data.scheme != "https") return null
            val url = data.toString()
            if (!isVideoUrl(url)) return null
            return RemoteVideoFrameFetcher(url, options, imageLoader.diskCache)
        }
    }

    private companion object {
        const val MAX_CONCURRENT = 2
        const val TIMEOUT_MS = 20_000L
        /** Long side of the stored frame; the feed decodes photos at 800 too. */
        const val MAX_SIDE = 800
        const val DISK_KEY_PREFIX = "video-frame:"
        /** API 26 full-size decode limit: 1080p. */
        const val MAX_FULL_DECODE_PIXELS = 1920L * 1080L

        /** Native reads in flight, including ones whose caller already timed out. */
        const val MAX_NATIVE_READS = 4

        val permits = Semaphore(MAX_CONCURRENT)
        val nativeReads = Semaphore(MAX_NATIVE_READS)
        val retrievalScope = CoroutineScope(SupervisorJob() + Dispatchers.IO)

        /**
         * One frame of [url], at most [MAX_SIDE] on its long side. Never decodes at
         * full size: a 4K or larger frame is tens of MB and can exhaust the heap.
         * Returns null without decoding once [active] turns false (caller timed out).
         */
        fun grabFrame(url: String, active: () -> Boolean): Bitmap? {
            val retriever = MediaMetadataRetriever()
            return try {
                retriever.setDataSource(url, HashMap())
                if (!active()) return null
                if (Build.VERSION.SDK_INT >= 27) {
                    // Fits within MAX_SIDE x MAX_SIDE keeping the aspect ratio, so
                    // no width/height metadata is needed to bound the decode.
                    retriever.getScaledFrameAtTime(
                        0, MediaMetadataRetriever.OPTION_CLOSEST_SYNC, MAX_SIDE, MAX_SIDE,
                    )
                } else {
                    // API 26 has no scaled decode: only take frames known to be small.
                    val w = retriever.extractMetadata(MediaMetadataRetriever.METADATA_KEY_VIDEO_WIDTH)?.toIntOrNull() ?: 0
                    val h = retriever.extractMetadata(MediaMetadataRetriever.METADATA_KEY_VIDEO_HEIGHT)?.toIntOrNull() ?: 0
                    if (w <= 0 || h <= 0 || w.toLong() * h > MAX_FULL_DECODE_PIXELS) return null
                    val full = retriever.getFrameAtTime(0, MediaMetadataRetriever.OPTION_CLOSEST_SYNC) ?: return null
                    val scale = minOf(1f, MAX_SIDE.toFloat() / maxOf(full.width, full.height))
                    if (scale < 1f) {
                        Bitmap.createScaledBitmap(full, (full.width * scale).toInt(), (full.height * scale).toInt(), true)
                            .also { if (it !== full) full.recycle() }
                    } else full
                }
            } catch (e: Exception) {
                null
            } finally {
                runCatching { retriever.release() }
            }
        }
    }
}
