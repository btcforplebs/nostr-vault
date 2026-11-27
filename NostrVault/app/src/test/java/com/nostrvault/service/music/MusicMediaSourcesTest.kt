package com.nostrvault.service.music

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/** Which items the music service reads through the video cache (a minimized clip). */
class MusicMediaSourcesTest {

    private val clip = "https://blossom.example/abc.mp4"

    @Test fun `a minimized clip on the web reads through the video cache`() {
        assertTrue(MusicMediaSources.readsThroughCache(PlayerTrack.videoId(clip), clip, null))
    }

    @Test fun `a song never touches the video cache`() {
        assertFalse(MusicMediaSources.readsThroughCache("wavlake-track-id", "https://op3.dev/song.mp3", null))
    }

    @Test fun `a live stream never touches the video cache`() {
        val hls = "https://cdn.example/live/index.m3u8"
        assertFalse(MusicMediaSources.readsThroughCache("live:30311:abc:d", hls, null))
        // Even if it were named as a clip, a playlist is never cached.
        assertFalse(MusicMediaSources.readsThroughCache(PlayerTrack.videoId(hls), hls, null))
    }

    @Test fun `a vault file plays from disk, not the cache`() {
        val file = "file:///data/user/0/com.nostrvault.app/files/blobs/abc.mp4"
        assertFalse(MusicMediaSources.readsThroughCache(PlayerTrack.videoId(file), file, null))
        val lan = "http://127.0.0.1:3355/abc.mp4"
        assertFalse(MusicMediaSources.readsThroughCache(PlayerTrack.videoId(lan), lan, null))
    }

    @Test fun `video ids round trip`() {
        assertTrue(PlayerTrack.isVideoId(PlayerTrack.videoId(clip)))
        assertFalse(PlayerTrack.isVideoId("live:x"))
    }
}
