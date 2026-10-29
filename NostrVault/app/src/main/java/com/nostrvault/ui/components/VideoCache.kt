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
 * again. HLS is left out: a live playlist keeps its address while its contents
 * change, so a cached copy would freeze the stream.
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
            uri.substringBefore('?').endsWith(".m3u8", ignoreCase = true)

    /** Plays [uri] through the cache unless it is HLS. */
    fun ExoPlayer.Builder.cachedFor(context: Context, uri: String, mimeType: String? = null): ExoPlayer.Builder {
        if (isHls(uri, mimeType)) return this
        val upstream = DefaultDataSource.Factory(context)
        val cached = CacheDataSource.Factory()
            .setCache(cache(context))
            .setUpstreamDataSourceFactory(upstream)
            .setFlags(CacheDataSource.FLAG_IGNORE_CACHE_ON_ERROR)
        return setMediaSourceFactory(DefaultMediaSourceFactory(cached))
    }
}
