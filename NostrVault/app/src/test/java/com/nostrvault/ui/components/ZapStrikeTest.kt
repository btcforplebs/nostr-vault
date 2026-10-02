package com.nostrvault.ui.components

import androidx.compose.ui.geometry.Offset
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import kotlin.math.abs
import kotlin.random.Random

/** The zap strike's shape, schedule and haptics — the iOS #119 numbers. */
class ZapStrikeTest {

    // ── Timing ──────────────────────────────────────────────────

    @Test fun `strike lasts until the afterglow fades`() {
        // 0.30 s to the strike, then the longer of 7 strobes x 45 ms and 0.55 s of glow.
        assertEquals(0.85, ZapBolt.TOTAL, 1e-9)
    }

    @Test fun `before the strike the leader steps across while the avatar charges`() {
        val first = ZapBolt.frame(0.0)
        assertEquals(0.0, first.charge!!, 1e-9)
        assertEquals(0.6 / 7, first.leaderReach!!, 1e-9)
        assertNull(first.strobe)
        assertNull(first.glow)
        assertFalse(first.flash)

        // Jumps, not a slide: the reach holds within a step (0.26 s / 7 = 37 ms).
        assertEquals(ZapBolt.frame(0.01).leaderReach!!, ZapBolt.frame(0.03).leaderReach!!, 1e-9)
        assertTrue(ZapBolt.frame(0.05).leaderReach!! > ZapBolt.frame(0.03).leaderReach!!)

        // Fully across (and past the button, so every vertex shows) once the leader time is up.
        val late = ZapBolt.frame(0.29)
        assertTrue(late.leaderReach!! >= 1.0)
        assertNull(late.strobe)
    }

    @Test fun `leader re-jitters to the next channel shape every 30 ms`() {
        assertEquals(0, ZapBolt.frame(0.01).leaderChannel)
        assertEquals(1, ZapBolt.frame(0.035).leaderChannel)
        assertEquals(2, ZapBolt.frame(0.065).leaderChannel)
        // Wraps over the 7 shapes.
        assertEquals(0, ZapBolt.frame(0.215).leaderChannel)
    }

    @Test fun `the return stroke flashes once and strobes through the brightness table`() {
        val strike = ZapBolt.frame(ZapBolt.STRIKE_AT)
        assertNull(strike.charge)
        assertNull(strike.leaderReach)
        assertEquals(0, strike.strobe)
        assertTrue(strike.flash)
        assertEquals(1.0, strike.strobeBrightness, 1e-9)

        val strobes = (0 until 7).map { ZapBolt.frame(ZapBolt.STRIKE_AT + it * ZapBolt.STROBE_STEP + 0.01) }
        assertEquals(listOf(0, 1, 2, 3, 4, 5, 6), strobes.map { it.strobe })
        assertEquals(listOf(1.0, 0.18, 0.95, 0.12, 0.75, 0.4, 0.2), strobes.map { it.strobeBrightness })
        assertEquals(listOf(true, false, false, false, false, false, false), strobes.map { it.flash })

        val after = ZapBolt.frame(ZapBolt.STRIKE_AT + 7 * ZapBolt.STROBE_STEP + 0.001)
        assertNull(after.strobe)
        assertFalse(after.flash)
        assertTrue(after.glow != null)
    }

    @Test fun `nothing is left on screen once the strike is over`() {
        val end = ZapBolt.frame(ZapBolt.TOTAL + 1e-6)
        assertNull(end.charge)
        assertNull(end.leaderReach)
        assertNull(end.strobe)
        assertNull(end.glow)
        assertFalse(end.flash)
    }

    @Test fun `afterglow rises fast and falls to nothing`() {
        assertEquals(0.0, ZapBolt.glowStrength(0.0), 1e-9)
        assertEquals(1.0, ZapBolt.glowStrength(0.1), 1e-9)
        assertEquals(0.5, ZapBolt.glowStrength(0.55), 1e-9)
        assertEquals(0.0, ZapBolt.glowStrength(1.0), 1e-9)
    }

    @Test fun `a sheet-confirmed zap waits for the sheet to clear`() {
        assertEquals(0, ZapBolt.sheetWaitMs(1_000, Long.MIN_VALUE))
        assertEquals(400, ZapBolt.sheetWaitMs(1_000, 1_000))
        assertEquals(150, ZapBolt.sheetWaitMs(1_250, 1_000))
        assertEquals(0, ZapBolt.sheetWaitMs(1_400, 1_000))
        // A payment slower than the sheet goes at once.
        assertEquals(0, ZapBolt.sheetWaitMs(5_000, 1_000))
    }

    // ── Shape ───────────────────────────────────────────────────

    @Test fun `channel is pinned to both ends and stays near the line`() {
        repeat(20) { seed ->
            val c = ZapBolt.channel(400f, Random(seed))
            assertEquals(65, c.size)
            assertEquals(ZapBolt.Point(0f, 0f), c.first())
            assertEquals(ZapBolt.Point(1f, 0f), c.last())
            // Shoves halve-ish each round from at most 95 dp: the sum bounds any vertex.
            var bound = 0f
            var spread = 95f
            repeat(6) { bound += spread; spread *= 0.58f }
            assertTrue(c.all { abs(it.side) <= bound })
        }
    }

    @Test fun `short and long strikes get two and three branches off the middle of the channel`() {
        repeat(20) { seed ->
            assertEquals(2, ZapBolt.branches(200f, Random(seed)).size)
            val long = ZapBolt.branches(500f, Random(seed))
            assertEquals(3, long.size)
            for (b in long) {
                assertTrue(b.fromIndex in 8..49)
                assertEquals(b.fromIndex / 64.0, b.reach, 1e-9)
                assertEquals(7, b.points.size)
                assertEquals(ZapBolt.Point(0f, 0f), b.points.first())
                // Each branch crackles off to one side only.
                val sides = b.points.drop(1).map { it.side }
                assertTrue(sides.all { it > -5f } || sides.all { it < 5f })
            }
        }
    }

    @Test fun `stored points map onto the line between avatar and button`() {
        val start = Offset(100f, 800f)
        val end = Offset(100f, 200f)
        assertEquals(start, ZapBolt.place(ZapBolt.Point(0f, 0f), start, end, 2f))
        assertEquals(end, ZapBolt.place(ZapBolt.Point(1f, 0f), start, end, 2f))
        // Going straight up, +side is to the right, in dp scaled by density.
        val mid = ZapBolt.place(ZapBolt.Point(0.5f, 10f), start, end, 2f)
        assertEquals(120f, mid.x, 1e-3f)
        assertEquals(500f, mid.y, 1e-3f)
    }

    @Test fun `a branch starts on the vertex it forks from`() {
        val branch = ZapBolt.branches(500f, Random(1)).first()
        val base = Offset(321f, 456f)
        val pts = ZapBolt.placeBranch(branch, base, Offset(0f, 1000f), Offset(0f, 0f), 3f)
        assertEquals(base, pts.first())
    }

    // ── Haptics ─────────────────────────────────────────────────

    @Test fun `charge is three rising ticks 90 ms apart`() {
        val w = ZapHapticPattern.render(ZapHapticPattern.CHARGE)
        val on = onsets(w)
        assertEquals(listOf(0L, 90L, 180L), on.map { it.first })
        assertEquals(listOf(89, 115, 140), on.map { it.second })
        assertEquals(190L, w.totalMs)
    }

    @Test fun `strike cracks at full strength, rumbles, and fades out with the strobes`() {
        val w = ZapHapticPattern.render(ZapHapticPattern.STRIKE)
        assertEquals(255, w.amplitudes[0])
        assertEquals(10L, w.timings[0])
        // The rumble starts 20 ms in and has died by 340 ms.
        assertEquals(340L, w.totalMs)
        val at = amplitudeAt(w)
        assertTrue(at(25) in 190..210)
        // Aftershocks on the 2nd and 4th strobe stand out from the rumble around them.
        assertTrue(at(95) > at(85) && at(95) > at(105))
        assertTrue(at(185) > at(175) && at(185) > at(195))
        // And the tail decays.
        assertTrue(at(300) < at(200))
        assertTrue(w.amplitudes.all { it in 0..255 })
    }

    @Test fun `on-off fallback mirrors iOS's impact generators`() {
        assertEquals(listOf(0L, 12L), ZapHapticPattern.CHARGE_ON_OFF.toList())
        // Heavy hit, then a rigid one 60 ms after the first began.
        val s = ZapHapticPattern.STRIKE_ON_OFF
        assertEquals(60L, s[0] + s[1] + s[2])
    }

    /** (start ms, amplitude) of each step where the vibrator turns on. */
    private fun onsets(w: ZapHapticPattern.Waveform): List<Pair<Long, Int>> {
        val out = ArrayList<Pair<Long, Int>>()
        var t = 0L
        var prev = 0
        for (i in w.timings.indices) {
            if (w.amplitudes[i] > 0 && prev == 0) out.add(t to w.amplitudes[i])
            prev = w.amplitudes[i]
            t += w.timings[i]
        }
        return out
    }

    private fun amplitudeAt(w: ZapHapticPattern.Waveform): (Long) -> Int = { ms ->
        var t = 0L
        var amp = 0
        for (i in w.timings.indices) {
            if (ms >= t && ms < t + w.timings[i]) { amp = w.amplitudes[i]; break }
            t += w.timings[i]
        }
        amp
    }
}
