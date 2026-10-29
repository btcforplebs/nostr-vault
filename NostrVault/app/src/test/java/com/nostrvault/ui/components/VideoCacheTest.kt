package com.nostrvault.ui.components

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/** HLS stays out of the video cache: a live playlist changes under one address. */
class VideoCacheTest {
    @Test fun `hls by extension or mime is not cached`() {
        assertTrue(VideoCache.isHls("https://x/live/index.m3u8", null))
        assertTrue(VideoCache.isHls("https://x/live/INDEX.M3U8?token=1", null))
        assertTrue(VideoCache.isHls("https://x/stream", "application/x-mpegURL"))
    }

    @Test fun `plain video files are cached`() {
        assertFalse(VideoCache.isHls("https://x/clip.mp4", "video/mp4"))
        assertFalse(VideoCache.isHls("https://x/clip.mp4?name=a.m3u8x", null))
    }
}
