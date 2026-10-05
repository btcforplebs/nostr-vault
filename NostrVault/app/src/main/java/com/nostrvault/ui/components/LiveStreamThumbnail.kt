package com.nostrvault.ui.components

import android.content.Context
import android.os.SystemClock
import androidx.compose.animation.Crossfade
import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.ImageBitmap
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.platform.LocalContext
import androidx.core.graphics.drawable.toBitmap
import coil.imageLoader
import coil.request.CachePolicy
import coil.request.ImageRequest
import coil.request.SuccessResult
import com.nostrvault.ui.theme.LocalNostrVaultColors
import kotlinx.coroutines.delay
import kotlinx.coroutines.isActive

/**
 * A live tile's picture: the stream's live frame, else its cover art, else a
 * plain backdrop. iOS: LiveStreamThumbnail in LiveFeedViews.swift.
 *
 * Not a plain AsyncImage, which keeps every picture on disk by URL for good.
 * Cloudflare Stream and the fly.dev radio hosts serve each new frame at one
 * fixed URL, so the first frame ever fetched would stay on the tile forever. A
 * stream's picture is only true while it is on air, so it is kept in memory
 * for a minute and fetched again while the tile is on screen.
 */
@Composable
fun LiveStreamThumbnail(urls: List<String>, modifier: Modifier = Modifier) {
    val context = LocalContext.current
    val colors = LocalNostrVaultColors.current
    var image by remember(urls) { mutableStateOf(LiveThumbnailCache.entry(urls)?.image) }

    // Again every minute while the tile is composed, so a fixed-URL frame
    // moves on too; the loop ends when the tile leaves.
    LaunchedEffect(urls) {
        while (isActive) {
            val held = LiveThumbnailCache.entry(urls)
            if (held != null) image = held.image
            if (held?.isFresh != true) {
                for (url in urls) {
                    val fetched = LiveThumbnailCache.fetch(context, url) ?: continue
                    image = fetched
                    break
                }
            }
            delay(LiveThumbnailCache.MAX_AGE_MS)
        }
    }

    Box(modifier.background(colors.primary.copy(alpha = 0.12f))) {
        Crossfade(targetState = image, label = "liveThumbnail") { shown ->
            if (shown != null) {
                Image(
                    bitmap = shown,
                    contentDescription = null,
                    contentScale = ContentScale.Crop,
                    modifier = Modifier.fillMaxSize(),
                )
            }
        }
    }
}

/** Live-tile pictures, in memory only (see [LiveStreamThumbnail]). */
private object LiveThumbnailCache {
    const val MAX_AGE_MS = 60_000L

    class Entry(val image: ImageBitmap, private val fetchedAt: Long) {
        val isFresh: Boolean get() = SystemClock.elapsedRealtime() - fetchedAt < MAX_AGE_MS
    }

    private val entries = java.util.concurrent.ConcurrentHashMap<String, Entry>()

    /** The best picture already held for these candidates, in their order. */
    fun entry(urls: List<String>): Entry? = urls.firstNotNullOfOrNull { entries[it] }

    /**
     * Fetches past every cache — a fixed-URL frame must be new each time.
     * zap.stream serves its `thumb.webp` as application/octet-stream, which
     * the decoder reads by its bytes.
     */
    suspend fun fetch(context: Context, url: String): ImageBitmap? {
        val request = ImageRequest.Builder(context)
            .data(url)
            .size(600)
            .memoryCachePolicy(CachePolicy.DISABLED)
            .diskCachePolicy(CachePolicy.DISABLED)
            .addHeader("Cache-Control", "no-cache")
            .build()
        val result = context.imageLoader.execute(request) as? SuccessResult ?: return null
        val image = runCatching { result.drawable.toBitmap().asImageBitmap() }.getOrNull() ?: return null
        if (entries.size > 200) entries.clear()
        entries[url] = Entry(image, SystemClock.elapsedRealtime())
        return image
    }
}
