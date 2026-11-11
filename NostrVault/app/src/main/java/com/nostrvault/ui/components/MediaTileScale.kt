package com.nostrvault.ui.components

import androidx.compose.foundation.background
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.layout.ContentScale

/**
 * How a grid tile draws its picture. A photo fills the tile. A video's frame is
 * drawn whole on a dark tile, since a phone's portrait video cropped to a
 * square showed only its middle and looked zoomed in (Logen 11-11). iOS:
 * VideoThumbnailView.
 */
internal fun mediaTileContentScale(isVideo: Boolean): ContentScale =
    if (isVideo) ContentScale.Fit else ContentScale.Crop

/** The dark tile a video's frame sits on, so the bars around it read as part of the tile. */
internal fun Modifier.videoTileBackground(isVideo: Boolean): Modifier =
    if (isVideo) background(Color.Black) else this

/**
 * Width ÷ height of the tile a portrait video gets: taller than square, so a
 * phone's upright video fills most of its tile instead of sitting between wide
 * black bars (Logen 11-11). A 9:16 frame fills 84% of a 2:3 tile's width; a
 * square tile left it 56%.
 */
internal const val TALL_VIDEO_TILE_ASPECT = 2f / 3f

/**
 * Width ÷ height for every tile in one grid row. Square, unless a video in the
 * row is portrait: then the whole row stands taller, so its tiles stay lined up.
 * [videoFrameRatios] holds, per tile, the decoded frame's width ÷ height for a
 * video, or null for a photo or a frame not decoded yet. A near-square frame
 * keeps the row square.
 */
internal fun mediaRowTileAspect(videoFrameRatios: List<Float?>): Float =
    if (videoFrameRatios.any { it != null && it < 0.95f }) TALL_VIDEO_TILE_ASPECT else 1f

/**
 * A grid's decoded video frame ratios, by URL. Seeded from what this session
 * already decoded ([MediaAspectCache]), so a row known to be tall opens tall.
 * The decoded frame decides, not `imeta dim`: many clients write `dim` from a
 * portrait video's unrotated landscape pixels.
 */
internal class VideoFrameRatios {
    private val ratios = androidx.compose.runtime.mutableStateMapOf<String, Float>()

    operator fun get(url: String): Float? = ratios[url] ?: MediaAspectCache.get(url)

    fun learned(url: String, width: Float, height: Float) {
        if (width <= 0f || height <= 0f || !width.isFinite() || !height.isFinite()) return
        val ratio = width / height
        if (ratios[url] == ratio) return
        ratios[url] = ratio
        MediaAspectCache.put(url, ratio)
    }

    /** Tile width ÷ height for the row of [urls]; only the videos among them count. */
    fun rowAspect(urls: List<String>, isVideo: (String) -> Boolean): Float =
        mediaRowTileAspect(urls.map { if (isVideo(it)) this[it] else null })
}
