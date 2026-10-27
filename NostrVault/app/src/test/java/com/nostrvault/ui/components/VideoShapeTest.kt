package com.nostrvault.ui.components

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File

/** Portrait videos at their own shape in the feed and full screen (Logen, 2026-10-22). */
class VideoShapeTest {
    private val portrait = 9f / 16f
    private val landscape = 16f / 9f

    @Test
    fun `a dim written the wrong way round gives way to the decoded frame`() {
        // A phone's upright video: landscape pixels and a rotate flag; dim from the pixels.
        assertEquals(portrait, videoBoxRatio(hinted = landscape, decoded = portrait)!!, 0.001f)
        assertEquals(landscape, videoBoxRatio(hinted = portrait, decoded = landscape)!!, 0.001f)
    }

    @Test
    fun `an agreeing or missing hint behaves as before`() {
        // Same orientation: the hint wins, so a pixel of rounding never moves the feed.
        assertEquals(0.56f, videoBoxRatio(hinted = 0.56f, decoded = portrait)!!, 0.001f)
        assertEquals(portrait, videoBoxRatio(hinted = null, decoded = portrait)!!, 0.001f)
        assertEquals(landscape, videoBoxRatio(hinted = landscape, decoded = null)!!, 0.001f)
        assertNull(videoBoxRatio(null, null))
        // Square on either side is not "the wrong way round".
        assertEquals(1f, videoBoxRatio(hinted = 1f, decoded = portrait)!!, 0.001f)
    }

    @Test
    fun `a portrait video never fills the screen`() {
        assertEquals(480f, feedVideoMaxHeightDp(800), 0.001f)  // 60%
        assertEquals(600f, feedVideoMaxHeightDp(1400), 0.001f) // and never more than a portrait photo
        assertTrue(feedVideoMaxHeightDp(915) < 915 * 0.61f)
    }

    @Test
    fun `the player's shape includes its pixel aspect ratio`() {
        assertEquals(portrait, videoDisplayAspect(720, 1280, 1f), 0.001f)
        assertEquals(16f / 9f, videoDisplayAspect(1440, 1080, 4f / 3f), 0.001f) // anamorphic
        assertEquals(0f, videoDisplayAspect(0, 1080, 1f), 0f)
    }

    /**
     * Wiring, source-level (Compose needs a device): the feed card and the carousel use the video
     * rules, a carousel video is not cropped, and full screen draws on a TextureView.
     */
    @Test
    fun `the composables use them`() {
        val base = "src/main/java/com/nostrvault/ui/components/"
        val single = File(base + "notecard/MediaPreviewRow.kt").readText()
        assertTrue(single.contains("if (isVideo) videoBoxRatio(hintedRatio, decodedRatio)"))
        assertTrue(single.contains("feedVideoMaxHeightDp(screenHeightDp)"))
        val carousel = File(base + "notecard/MediaCarousel.kt").readText()
        assertTrue(carousel.contains("if (isVideoUrl(url)) ContentScale.Fit else ContentScale.Crop"))
        assertTrue(carousel.contains("videoBoxRatio(firstRatio, firstDecoded)"))
        assertTrue(carousel.contains("config.screenWidthDp / feedVideoMaxHeightDp(config.screenHeightDp)"))
        val player = File(base + "VideoPlayer.kt").readText()
        val surface = player.substringAfter("internal fun VideoSurface(")
        assertTrue(surface.contains("setVideoTextureView") && !surface.contains("PlayerView(ctx)"))
    }
}
