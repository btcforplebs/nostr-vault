package com.nostrvault.ui.components

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/** Live playlists (they change under one address) and local files stay out of the video cache. */
class VideoCacheTest {
    @Test fun `hls by extension or mime is not cached`() {
        assertTrue(VideoCache.isHls("https://x/live/index.m3u8", null))
        assertTrue(VideoCache.isHls("https://x/live/INDEX.M3U8?token=1", null))
        assertTrue(VideoCache.isHls("https://x/stream", "application/x-mpegURL"))
        assertTrue(VideoCache.isHls("https://x/live/manifest.mpd", null))
        assertTrue(VideoCache.isHls("https://x/stream", "application/dash+xml"))
    }

    @Test fun `the vault's own files are not cached`() {
        assertTrue(VideoCache.isLocal("file:///data/user/0/x/files/a.mp4"))
        assertTrue(VideoCache.isLocal("content://media/external/video/1"))
        assertTrue(VideoCache.isLocal("http://127.0.0.1:3355/abc.mp4"))
        assertTrue(VideoCache.isLocal("http://localhost:3355/abc.mp4"))
        assertTrue(VideoCache.isLocal("http://192.168.1.20:3355/abc.mp4"))
        assertTrue(VideoCache.isLocal("http://10.44.194.35/abc.mp4"))
        assertTrue(VideoCache.isLocal("http://172.20.0.2/abc.mp4"))
        assertTrue(VideoCache.isLocal("/data/user/0/x/files/a.mp4"))
    }

    @Test fun `remote servers are cached`() {
        assertFalse(VideoCache.isLocal("https://blossom.primal.net/abc.mp4"))
        assertFalse(VideoCache.isLocal("https://172.32.0.1/abc.mp4"))
        assertFalse(VideoCache.skipsCache("https://x/clip.mp4", "video/mp4"))
    }

    @Test fun `plain video files are cached`() {
        assertFalse(VideoCache.isHls("https://x/clip.mp4", "video/mp4"))
        assertFalse(VideoCache.isHls("https://x/clip.mp4?name=a.m3u8x", null))
    }
}
