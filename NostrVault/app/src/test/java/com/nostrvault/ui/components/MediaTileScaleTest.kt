package com.nostrvault.ui.components

import androidx.compose.ui.geometry.Size
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class MediaTileScaleTest {
    private val tile = Size(360f, 360f)

    /** The size the picture is drawn at in [tile]. */
    private fun drawn(src: Size, isVideo: Boolean): Size {
        val s = mediaTileContentScale(isVideo).computeScaleFactor(src, tile)
        return Size(src.width * s.scaleX, src.height * s.scaleY)
    }

    private fun assertWhole(src: Size) {
        val d = drawn(src, isVideo = true)
        assertTrue("video $src drawn $d is cut by the tile", d.width <= tile.width + 0.5f && d.height <= tile.height + 0.5f)
        assertTrue("video $src drawn $d does not reach the tile's edge", d.width >= tile.width - 0.5f || d.height >= tile.height - 0.5f)
    }

    @Test fun portraitVideoShowsWholeFrame() = assertWhole(Size(1080f, 1920f))

    @Test fun landscapeVideoShowsWholeFrame() = assertWhole(Size(1920f, 1080f))

    @Test fun photoStillFillsTile() {
        for (src in listOf(Size(1080f, 1920f), Size(1920f, 1080f))) {
            val d = drawn(src, isVideo = false)
            assertTrue("photo $src drawn $d leaves bars", d.width >= tile.width - 0.5f && d.height >= tile.height - 0.5f)
        }
    }

    // ---- Taller tiles for portrait videos (Logen 11-11) ----

    private val phonePortrait = 1080f / 1920f
    private val phoneLandscape = 1920f / 1080f

    /** Share of a tile [aspect] (width ÷ height, width 360) a [src] video frame covers when drawn. */
    private fun covered(src: Size, aspect: Float): Float {
        val t = Size(360f, 360f / aspect)
        val s = mediaTileContentScale(isVideo = true).computeScaleFactor(src, t)
        return (src.width * s.scaleX * src.height * s.scaleY) / (t.width * t.height)
    }

    /** Fails on the old square tile: a 9:16 video there covered 56%, the rest black bars. */
    @Test fun portraitVideoFillsMostOfItsTile() {
        val aspect = mediaRowTileAspect(listOf(null, phonePortrait, null))
        val c = covered(Size(1080f, 1920f), aspect)
        assertTrue("portrait video covers only ${(c * 100).toInt()}% of its tile", c >= 0.8f)
    }

    @Test fun rowWithoutPortraitVideoStaysSquare() {
        assertEquals(1f, mediaRowTileAspect(listOf(null, null, null)), 0f)
        assertEquals(1f, mediaRowTileAspect(listOf(phoneLandscape, null)), 0f)
        assertEquals(1f, mediaRowTileAspect(listOf(1f, null)), 0f) // square video
        assertEquals(1f, mediaRowTileAspect(emptyList()), 0f)
    }

    @Test fun portraitVideoMakesItsWholeRowTall() {
        assertEquals(TALL_VIDEO_TILE_ASPECT, mediaRowTileAspect(listOf(phoneLandscape, phonePortrait, null)), 0f)
    }

    @Test fun portraitVideoStillShownWholeInTallTile() {
        val t = Size(360f, 360f / TALL_VIDEO_TILE_ASPECT)
        val s = mediaTileContentScale(isVideo = true).computeScaleFactor(Size(1080f, 1920f), t)
        assertTrue(1080f * s.scaleX <= t.width + 0.5f && 1920f * s.scaleY <= t.height + 0.5f)
    }

    @Test fun learnedFrameDecidesNotItsRotationlessDim() {
        MediaAspectCache.clear()
        val r = VideoFrameRatios()
        assertEquals(1f, r.rowAspect(listOf("a.mp4", "b.jpg")) { it.endsWith(".mp4") }, 0f)
        r.learned("a.mp4", 1080f, 1920f)
        assertEquals(TALL_VIDEO_TILE_ASPECT, r.rowAspect(listOf("a.mp4", "b.jpg")) { it.endsWith(".mp4") }, 0f)
        // A portrait-shaped photo does not raise the row.
        r.learned("b.jpg", 1080f, 1920f)
        assertEquals(1f, r.rowAspect(listOf("b.jpg")) { it.endsWith(".mp4") }, 0f)
        MediaAspectCache.clear()
    }
}
