package com.nostrvault.widget

import android.content.Context
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.LinearGradient
import android.graphics.Paint
import android.graphics.Shader
import android.media.MediaMetadataRetriever
import android.util.Log
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.async
import kotlinx.coroutines.awaitAll
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.withContext
import kotlinx.coroutines.withTimeoutOrNull
import okhttp3.OkHttpClient
import okhttp3.Request
import java.io.File
import java.io.FileInputStream
import java.net.URI
import java.security.MessageDigest
import java.util.concurrent.TimeUnit
import kotlin.math.max
import kotlin.math.roundToInt

/**
 * Bitmaps for the widgets, made before a widget composes.
 *
 * A Glance composable draws once into RemoteViews and cannot wait on a
 * download, so every picture is decoded — and shrunk — by the widget's
 * provideGlance. Shrunk because RemoteViews carry their bitmaps across to the
 * launcher process and the platform caps the total; a full-resolution photo
 * per tile would blow that cap and the widget would fail to draw at all.
 *
 * Mirrors iOS NVTileFetcher: local bytes first, remote fetched best-effort and
 * time-boxed, so a slow host costs a tile and never the whole widget.
 */
object WidgetImages {
    private const val TAG = "WidgetImages"
    private const val FETCH_TIMEOUT_SECONDS = 4L
    private const val OVERALL_TIMEOUT_MS = 10_000L
    private const val MAX_BYTES = 15L * 1024 * 1024

    private val client: OkHttpClient by lazy {
        OkHttpClient.Builder()
            .connectTimeout(FETCH_TIMEOUT_SECONDS, TimeUnit.SECONDS)
            .readTimeout(FETCH_TIMEOUT_SECONDS, TimeUnit.SECONDS)
            .callTimeout(FETCH_TIMEOUT_SECONDS * 2, TimeUnit.SECONDS)
            .build()
    }

    /**
     * Square-ish thumbnails for [items] keyed by their id. Missing entries are
     * tiles that could not be had; the caller draws a tinted fallback.
     *
     * @param remoteLimit how many network fetches one refresh may spend.
     */
    suspend fun load(
        context: Context,
        items: List<Source>,
        maxPixel: Int,
        remoteLimit: Int = 12,
    ): Map<String, Bitmap> = withContext(Dispatchers.IO) {
        val remoteAllowed = items.filter { it.localPath == null && isFetchable(it.url) }
            .take(remoteLimit).map { it.id }.toSet()
        val result = withTimeoutOrNull(OVERALL_TIMEOUT_MS) {
            coroutineScope {
                items.map { item ->
                    async {
                        val bmp = runCatching {
                            item.localPath?.let { decodeFile(File(it), maxPixel) }
                                ?: if (item.id in remoteAllowed) remote(context, item.url, maxPixel) else null
                        }.onFailure { Log.d(TAG, "tile ${item.id}: ${it.message}") }.getOrNull()
                        bmp?.let { item.id to it }
                    }
                }.awaitAll().filterNotNull().toMap()
            }
        }
        result ?: emptyMap()
    }

    data class Source(val id: String, val url: String, val localPath: String? = null)

    /** Image first, then a video's poster frame: Blossom names say nothing about type. */
    fun decodeFile(file: File, maxPixel: Int): Bitmap? {
        if (!file.isFile) return null
        return decodeImage(file, maxPixel) ?: videoFrame(file, maxPixel)
    }

    private fun decodeImage(file: File, maxPixel: Int): Bitmap? {
        val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }
        FileInputStream(file).use { BitmapFactory.decodeStream(it, null, bounds) }
        if (bounds.outWidth <= 0 || bounds.outHeight <= 0) return null
        val opts = BitmapFactory.Options().apply {
            inSampleSize = sampleSizeFor(bounds.outWidth, bounds.outHeight, maxPixel)
        }
        val decoded = FileInputStream(file).use { BitmapFactory.decodeStream(it, null, opts) } ?: return null
        return scaleDown(decoded, maxPixel)
    }

    private fun videoFrame(file: File, maxPixel: Int): Bitmap? {
        val retriever = MediaMetadataRetriever()
        return try {
            retriever.setDataSource(file.absolutePath)
            // Half a second in: frame zero is black on a lot of footage.
            val frame = retriever.getFrameAtTime(500_000, MediaMetadataRetriever.OPTION_CLOSEST_SYNC)
                ?: return null
            scaleDown(frame, maxPixel)
        } catch (e: Exception) {
            null
        } finally {
            runCatching { retriever.release() }
        }
    }

    /**
     * A remote picture, downloaded once and kept shrunk in the cache dir: a
     * widget refreshes on a timer and the same avatars come back every time.
     */
    private fun remote(context: Context, url: String, maxPixel: Int): Bitmap? {
        val cached = cacheFile(context, url, maxPixel)
        if (cached.isFile) {
            BitmapFactory.decodeFile(cached.absolutePath)?.let { return it }
        }
        val request = Request.Builder().url(url).get().build()
        val tmp = File(cached.parentFile, cached.name + ".download")
        client.newCall(request).execute().use { response ->
            if (!response.isSuccessful) return null
            val body = response.body ?: return null
            if (body.contentLength() > MAX_BYTES) return null
            tmp.outputStream().use { out ->
                val input = body.byteStream()
                val buf = ByteArray(64 * 1024)
                var total = 0L
                while (true) {
                    val n = input.read(buf)
                    if (n < 0) break
                    total += n
                    if (total > MAX_BYTES) return null.also { tmp.delete() }
                    out.write(buf, 0, n)
                }
            }
        }
        val bitmap = try { decodeFile(tmp, maxPixel) } finally { tmp.delete() }
        if (bitmap != null) {
            runCatching {
                cached.outputStream().use { bitmap.compress(Bitmap.CompressFormat.JPEG, 80, it) }
            }
        }
        return bitmap
    }

    private fun cacheFile(context: Context, url: String, maxPixel: Int): File {
        val dir = File(context.cacheDir, "widget-tiles").apply { mkdirs() }
        val digest = MessageDigest.getInstance("SHA-256").digest(url.toByteArray())
            .joinToString("") { "%02x".format(it) }
        return File(dir, "$digest-$maxPixel.jpg")
    }

    /**
     * The relay serves its own blobs from localhost, and only while it runs.
     * Those come from disk or not at all; a 4 s timeout on each would only
     * delay every other tile.
     */
    private fun isFetchable(url: String): Boolean {
        val uri = runCatching { URI(url) }.getOrNull() ?: return false
        if (uri.scheme != "https" && uri.scheme != "http") return false
        val host = uri.host?.lowercase() ?: return false
        return host != "127.0.0.1" && host != "localhost" && host != "::1" && host != "[::1]"
    }

    private fun scaleDown(src: Bitmap, maxPixel: Int): Bitmap {
        val long = max(src.width, src.height)
        if (long <= maxPixel) return src
        val scale = maxPixel.toFloat() / long
        val out = Bitmap.createScaledBitmap(
            src,
            (src.width * scale).roundToInt().coerceAtLeast(1),
            (src.height * scale).roundToInt().coerceAtLeast(1),
            true,
        )
        if (out !== src) src.recycle()
        return out
    }

    /**
     * The centre square of [src], optionally cut to a circle. Glance's own
     * corner rounding only exists from Android 12, and an avatar that turns
     * square on older phones reads as a different design.
     */
    fun square(src: Bitmap, size: Int, circle: Boolean): Bitmap {
        val out = Bitmap.createBitmap(size, size, Bitmap.Config.ARGB_8888)
        val canvas = Canvas(out)
        val paint = Paint(Paint.ANTI_ALIAS_FLAG or Paint.FILTER_BITMAP_FLAG)
        val side = minOf(src.width, src.height)
        val left = (src.width - side) / 2
        val top = (src.height - side) / 2
        val srcRect = android.graphics.Rect(left, top, left + side, top + side)
        val dstRect = android.graphics.Rect(0, 0, size, size)
        if (circle) {
            canvas.drawCircle(size / 2f, size / 2f, size / 2f, paint)
            paint.xfermode = android.graphics.PorterDuffXfermode(android.graphics.PorterDuff.Mode.SRC_IN)
        }
        canvas.drawBitmap(src, srcRect, dstRect, paint)
        return out
    }

    /**
     * A tinted stand-in keyed to [seed], so a missing picture still reads as
     * media (or as a person) rather than as a failure — and two different
     * authors do not get the same grey circle.
     */
    fun fallback(seed: String, size: Int, circle: Boolean, strong: Float, weak: Float): Bitmap {
        val hue = seededHue(seed)
        val a = Color.HSVToColor((strong * 255).toInt(), floatArrayOf(hue, 0.55f, 0.85f))
        val b = Color.HSVToColor((weak * 255).toInt(), floatArrayOf(hue, 0.55f, 0.85f))
        val out = Bitmap.createBitmap(size, size, Bitmap.Config.ARGB_8888)
        val paint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
            shader = LinearGradient(0f, 0f, size.toFloat(), size.toFloat(), a, b, Shader.TileMode.CLAMP)
        }
        val canvas = Canvas(out)
        if (circle) canvas.drawCircle(size / 2f, size / 2f, size / 2f, paint)
        else canvas.drawRect(0f, 0f, size.toFloat(), size.toFloat(), paint)
        return out
    }
}
