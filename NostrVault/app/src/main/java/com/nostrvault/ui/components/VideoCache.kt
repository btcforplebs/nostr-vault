package com.nostrvault.ui.components

import android.content.Context
import androidx.annotation.OptIn
import androidx.media3.common.MimeTypes
import androidx.media3.common.util.UnstableApi
import androidx.media3.database.StandaloneDatabaseProvider
import androidx.media3.datasource.DefaultDataSource
import androidx.media3.datasource.cache.CacheDataSource
import androidx.media3.datasource.cache.LeastRecentlyUsedCacheEvictor
import androidx.media3.datasource.cache.SimpleCache
import androidx.media3.exoplayer.ExoPlayer
import androidx.media3.exoplayer.source.DefaultMediaSourceFactory
import java.io.File

/**
 * One on-disk cache for the looping video players. Without it a looping clip
 * was downloaded again on every loop, and scrolling back to a video fetched it
 * again. HLS and DASH are left out: a live playlist keeps its address while
 * its contents change, so a cached copy would freeze the stream. The vault's
 * own files (file:, content:, the local relay or a LAN host) are left out too:
 * a copy saves no data and would outlive a deleted video until LRU evicts it.
 */
@OptIn(UnstableApi::class)
object VideoCache {
    private const val MAX_BYTES = 256L * 1024 * 1024

    @Volatile private var cache: SimpleCache? = null

    private fun cache(context: Context): SimpleCache = cache ?: synchronized(this) {
        cache ?: SimpleCache(
            File(context.applicationContext.cacheDir, "video-cache"),
            LeastRecentlyUsedCacheEvictor(MAX_BYTES),
            StandaloneDatabaseProvider(context.applicationContext),
        ).also { cache = it }
    }

    fun isHls(uri: String, mimeType: String?): Boolean =
        mimeType == MimeTypes.APPLICATION_M3U8 ||
            mimeType == MimeTypes.APPLICATION_MPD ||
            uri.substringBefore('?').let {
                it.endsWith(".m3u8", ignoreCase = true) || it.endsWith(".mpd", ignoreCase = true)
            }

    /** True for files already on this device or on the home network. */
    fun isLocal(uri: String): Boolean {
        val parsed = runCatching { java.net.URI(uri) }.getOrNull() ?: return true
        val scheme = parsed.scheme?.lowercase() ?: return true
        if (scheme != "http" && scheme != "https") return true
        val host = parsed.host?.lowercase()?.trim('[', ']') ?: return true
        if (host == "localhost" || host.endsWith(".local") || host == "::1") return true
        val parts = host.split('.').mapNotNull { it.toIntOrNull() }
        if (parts.size != 4) return false
        return parts[0] == 127 || parts[0] == 10 ||
            (parts[0] == 192 && parts[1] == 168) ||
            (parts[0] == 172 && parts[1] in 16..31) ||
            (parts[0] == 169 && parts[1] == 254)
    }

    fun skipsCache(uri: String, mimeType: String?): Boolean = isHls(uri, mimeType) || isLocal(uri)

    /** Plays [uri] through the cache unless it is a live playlist or a local file. */
    fun ExoPlayer.Builder.cachedFor(context: Context, uri: String, mimeType: String? = null): ExoPlayer.Builder {
        if (skipsCache(uri, mimeType)) return this
        val upstream = DefaultDataSource.Factory(context)
        val cached = CacheDataSource.Factory()
            .setCache(cache(context))
            .setUpstreamDataSourceFactory(upstream)
            .setFlags(CacheDataSource.FLAG_IGNORE_CACHE_ON_ERROR)
        return setMediaSourceFactory(DefaultMediaSourceFactory(cached))
    }
}
