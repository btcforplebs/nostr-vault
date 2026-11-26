package com.nostrvault.service.media

import com.nostrvault.service.media.ImageCompressor.Quality
import com.nostrvault.service.media.VideoCompressor.Plan
import com.nostrvault.service.media.VideoCompressor.Source
import org.junit.Assert.assertEquals
import org.junit.Test

/** The size rules of plan D3 (Logen 2026-11-26: real 720p = short edge 720, 5 Mbps). */
class VideoCompressorTest {
    private fun plan(w: Int, h: Int, bps: Int, mime: String? = "video/avc", q: Quality = Quality.STANDARD) =
        VideoCompressor.plan(Source(w, h, bps, mime), q)

    @Test fun `4K phone clip goes to 720 short edge at 5 Mbps`() {
        assertEquals(Plan.Encode(shortSide = 720, bitrate = 5_000_000), plan(3840, 2160, 50_000_000, "video/hevc"))
    }

    @Test fun `portrait clip scales by its short edge too`() {
        assertEquals(Plan.Encode(shortSide = 720, bitrate = 5_000_000), plan(2160, 3840, 40_000_000))
    }

    @Test fun `1080p clip goes to 1280x720`() {
        assertEquals(Plan.Encode(shortSide = 720, bitrate = 5_000_000), plan(1920, 1080, 17_000_000))
    }

    @Test fun `720p H264 clip keeps its bytes`() {
        assertEquals(Plan.Keep, plan(1280, 720, 2_000_000))
        assertEquals(Plan.Keep, plan(720, 1280, 6_000_000))
    }

    @Test fun `720p but over 6 Mbps is re-encoded at 5 without resize`() {
        assertEquals(Plan.Encode(shortSide = null, bitrate = 5_000_000), plan(1280, 720, 8_000_000))
    }

    @Test fun `small clip is never enlarged`() {
        assertEquals(Plan.Encode(shortSide = null, bitrate = 1_500_000), plan(640, 360, 1_500_000, "video/hevc"))
        assertEquals(Plan.Encode(shortSide = null, bitrate = 5_000_000), plan(854, 480, 9_000_000))
    }

    @Test fun `just over 720 short edge never keeps even at low bitrate, and never grows`() {
        assertEquals(Plan.Encode(shortSide = 720, bitrate = 3_000_000), plan(1440, 1080, 3_000_000))
    }

    @Test fun `unknown size or bitrate is re-encoded at the cap`() {
        assertEquals(Plan.Encode(shortSide = null, bitrate = 5_000_000), plan(0, 0, 0))
    }

    @Test fun `Original keeps every byte`() {
        assertEquals(Plan.Keep, plan(3840, 2160, 50_000_000, q = Quality.ORIGINAL))
    }
}
