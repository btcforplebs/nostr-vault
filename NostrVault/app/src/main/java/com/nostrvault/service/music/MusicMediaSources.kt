package com.nostrvault.service.music

import android.content.Context
import androidx.media3.common.C
import androidx.media3.common.MediaItem
import androidx.media3.common.util.UnstableApi
import androidx.media3.exoplayer.drm.DrmSessionManagerProvider
import androidx.media3.exoplayer.source.DefaultMediaSourceFactory
import androidx.media3.exoplayer.source.MediaSource
import androidx.media3.exoplayer.upstream.LoadErrorHandlingPolicy
import com.nostrvault.ui.components.VideoCache

/**
 * Where the music service reads each item from. A minimized video clip
 * ([PlayerTrack.isVideo]) reads through the viewers' video cache, so the copy
 * the full-screen viewer already fetched plays in the mini player without a
 * second download. Songs and live streams keep the plain path: songs would
 * crowd the clips out of the cache, and a live playlist must never be cached
 * (VideoCache).
 */
@UnstableApi
class MusicMediaSources(context: Context) : MediaSource.Factory {
    private val plain = DefaultMediaSourceFactory(context)
    private val cached = VideoCache.cachedSourceFactory(context)

    override fun setDrmSessionManagerProvider(provider: DrmSessionManagerProvider): MediaSource.Factory = apply {
        plain.setDrmSessionManagerProvider(provider)
        cached.setDrmSessionManagerProvider(provider)
    }

    override fun setLoadErrorHandlingPolicy(policy: LoadErrorHandlingPolicy): MediaSource.Factory = apply {
        plain.setLoadErrorHandlingPolicy(policy)
        cached.setLoadErrorHandlingPolicy(policy)
    }

    override fun getSupportedTypes(): @C.ContentType IntArray = plain.supportedTypes

    override fun createMediaSource(mediaItem: MediaItem): MediaSource =
        (if (readsThroughCache(mediaItem)) cached else plain).createMediaSource(mediaItem)

    companion object {
        /** A minimized clip on the web, not a playlist or a file of the vault's own. */
        fun readsThroughCache(item: MediaItem): Boolean {
            val config = item.localConfiguration ?: return false
            return readsThroughCache(item.mediaId, config.uri.toString(), config.mimeType)
        }

        fun readsThroughCache(mediaId: String, uri: String, mimeType: String?): Boolean =
            PlayerTrack.isVideoId(mediaId) && !VideoCache.skipsCache(uri, mimeType)
    }
}
