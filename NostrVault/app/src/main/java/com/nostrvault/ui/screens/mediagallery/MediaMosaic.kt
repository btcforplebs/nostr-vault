package com.nostrvault.ui.screens

import java.io.File

/**
 * Vault › Media as a mosaic: the Android twin of Apple's `MediaMosaicLayout`
 * (PR #2193) and the web's `net/media-mosaic.js` (#2204).
 *
 * Each photo or video keeps its own shape in fixed-width columns
 * (`LazyVerticalStaggeredGrid` puts each tile in the shortest column). Every
 * tile's height is known before its picture loads, so nothing moves when it
 * arrives. A tile whose shape isn't known yet is square.
 *
 * Shapes come from, in order: a local file's header (read off the main
 * thread before the grid shows, EXIF rotation counted, as Apple's scan does),
 * then a shape learned from the picture on an earlier visit ([MediaMosaicSizes]).
 */
internal object MediaMosaicLayout {
    /** Narrowest shape a tile may take, as width ÷ height: twice as tall as wide. */
    const val MIN_ASPECT = 0.5f
    /** Widest shape: twice as wide as tall. */
    const val MAX_ASPECT = 2f

    /** [aspect] limited to what a tile may show; 1 (square) when unknown. */
    fun clampedAspect(aspect: Float?): Float =
        if (aspect == null || !aspect.isFinite() || aspect <= 0f) 1f else aspect.coerceIn(MIN_ASPECT, MAX_ASPECT)

    /** Columns for a grid [widthDp] wide: 3 on a phone, more on a fold or tablet (iPad 3–6, Mac 4). */
    fun columnsFor(widthDp: Float): Int = when {
        widthDp < 600f -> 3
        widthDp < 900f -> 4
        widthDp < 1200f -> 5
        else -> 6
    }

    /** Width ÷ height as shown: EXIF orientations 5–8 turn the picture a quarter. */
    fun shownAspect(pixelWidth: Int, pixelHeight: Int, orientation: Int): Float? {
        if (pixelWidth <= 0 || pixelHeight <= 0) return null
        return if (orientation in 5..8) pixelHeight.toFloat() / pixelWidth else pixelWidth.toFloat() / pixelHeight
    }

    /** Width ÷ height of an image file, from its header only (no decode). Call off the main thread. */
    fun imageFileAspect(file: File): Float? = runCatching {
        val bounds = android.graphics.BitmapFactory.Options().apply { inJustDecodeBounds = true }
        android.graphics.BitmapFactory.decodeFile(file.path, bounds)
        val orientation = runCatching {
            androidx.exifinterface.media.ExifInterface(file.path)
                .getAttributeInt(androidx.exifinterface.media.ExifInterface.TAG_ORIENTATION, 1)
        }.getOrDefault(1)
        shownAspect(bounds.outWidth, bounds.outHeight, orientation)
    }.getOrNull()
}

/**
 * Shapes learned from pictures that loaded, by blob hash, kept across launches.
 * A grid reads them once when it goes up ([snapshot]), so a shape learned while
 * it is on screen never moves a tile there; the next visit uses it. Writes are
 * batched. Stored as "hash aspect" lines (no JSON, so the JVM tests need no Android).
 */
internal class MediaMosaicSizes(
    private val read: () -> String?,
    private val write: (String) -> Unit,
    private val schedule: (Runnable) -> Unit,
) {
    private val pending = LinkedHashMap<String, Float>()
    private var scheduled = false

    @Synchronized
    fun snapshot(): Map<String, Float> = parse(read()).apply { putAll(pending) }

    /** Keep the shape of a picture that loaded ([width] x [height]) for the next visit. */
    @Synchronized
    fun learn(sha256: String, width: Float, height: Float) {
        if (!HEX64.matches(sha256) || !(width > 0f) || !(height > 0f) || !width.isFinite() || !height.isFinite()) return
        pending[sha256] = Math.round(width / height * 1000f) / 1000f
        if (!scheduled) { scheduled = true; schedule(Runnable { flush() }) }
    }

    /** Write what was learned, oldest dropped past [CAP]. */
    @Synchronized
    fun flush() {
        scheduled = false
        if (pending.isEmpty()) return
        val all = parse(read())
        for ((k, a) in pending) { all.remove(k); all[k] = a }
        pending.clear()
        val keep = all.entries.toList().takeLast(CAP)
        write(keep.joinToString("\n") { "${it.key} ${it.value}" })
    }

    companion object {
        const val CAP = 3000
        private val HEX64 = Regex("^[0-9a-f]{64}$")

        private fun parse(text: String?): LinkedHashMap<String, Float> {
            val out = LinkedHashMap<String, Float>()
            for (line in text.orEmpty().lineSequence()) {
                val space = line.indexOf(' ')
                if (space <= 0) continue
                val k = line.substring(0, space)
                val a = line.substring(space + 1).toFloatOrNull() ?: continue
                if (HEX64.matches(k) && a > 0f && a.isFinite()) out[k] = a
            }
            return out
        }

        @Volatile private var shared: MediaMosaicSizes? = null

        /** The app's store, in its own SharedPreferences, written 1.5 s after the first new shape. */
        fun of(context: android.content.Context): MediaMosaicSizes = shared ?: synchronized(this) {
            shared ?: run {
                val prefs = context.applicationContext.getSharedPreferences("media_mosaic_shapes", android.content.Context.MODE_PRIVATE)
                val main = android.os.Handler(android.os.Looper.getMainLooper())
                MediaMosaicSizes(
                    read = { prefs.getString("shapes", null) },
                    write = { prefs.edit().putString("shapes", it).apply() },
                    schedule = { main.postDelayed(it, 1500) },
                ).also { shared = it }
            }
        }
    }
}
