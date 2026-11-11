package com.nostrvault.ui.components

import androidx.compose.ui.geometry.Size
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
}
