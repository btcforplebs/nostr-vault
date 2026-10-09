package com.nostrvault.data.model

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.text.NumberFormat

class WotRefreshProgressTest {

    @Test fun `parses the relay's progress`() {
        val p = WotRefreshProgress.parse(
            """{"running":true,"phase":"lists","batches":8,"batchesDone":2,"lists":1234,"size":0,"finishedAt":0}""",
        )!!
        assertTrue(p.running)
        assertEquals("lists", p.phase)
        assertEquals(8, p.batches)
        assertEquals(2, p.batchesDone)
        assertEquals(1234L, p.lists)
        assertEquals(0.25 + 0.7 * 2 / 8, p.fraction(0.0), 1e-9)
        assertEquals("Reading your follows' lists… part 3 of 8", p.caption)
        assertEquals("Reading your follows' lists… part 8 of 8", p.copy(batchesDone = 8).caption)
        assertEquals("Reading your follows' lists…", p.copy(batches = 1, batchesDone = 0).caption)
    }

    private fun creep(t: Double) = 1 - kotlin.math.exp(-t / 25)

    @Test fun `fraction by phase`() {
        fun f(phase: String, t: Double = 0.0, batches: Int = 0, done: Int = 0) =
            WotRefreshProgress(running = true, phase = phase, batches = batches, batchesDone = done).fraction(t)
        assertEquals(0.02, f("follows"), 1e-9)
        assertEquals(0.02 + 0.2 * creep(56.0), f("follows", 56.0), 1e-9)
        assertTrue(f("follows", 1e6) <= 0.22 + 1e-9)
        // No batches yet: done 0, next 1, so the whole share creeps.
        assertEquals(0.25, f("lists"), 1e-9)
        assertEquals(0.25 + 0.7 * creep(10.0), f("lists", 10.0), 1e-9)
        // 2 of 8 done, creeping toward 3 of 8.
        assertEquals(0.25 + 0.7 * (2.0 / 8), f("lists", 0.0, 8, 2), 1e-9)
        assertEquals(0.25 + 0.7 * (2.0 / 8 + (1.0 / 8) * creep(25.0)), f("lists", 25.0, 8, 2), 1e-9)
        // All done: nowhere further to creep, and never past its share.
        assertEquals(0.95, f("lists", 100.0, 4, 4), 1e-9)
        assertEquals(0.95, f("lists", 100.0, 4, 9), 1e-9)
        assertEquals(0.97, f("counting", 30.0), 1e-9)
        assertEquals(1.0, f("saved"), 1e-9)
        assertEquals(1.0, f("stopped"), 1e-9)
        assertEquals(1.0, f(""), 1e-9)
        // A clock that ran backwards doesn't move the bar back past the mark.
        assertEquals(0.02, f("follows", -5.0), 1e-9)
    }

    @Test fun `the creep only moves forward`() {
        val p = WotRefreshProgress(running = true, phase = "lists", batches = 5, batchesDone = 1)
        var last = -1.0
        for (t in 0..300) {
            val now = p.fraction(t.toDouble())
            assertTrue(now >= last)
            last = now
        }
    }

    @Test fun `captions by phase`() {
        fun c(phase: String, size: Int = 0) = WotRefreshProgress(running = false, phase = phase, size = size).caption
        assertEquals("Reading your follow list…", c("follows"))
        assertEquals("Counting who your web trusts…", c("counting"))
        assertEquals("Your web: ${NumberFormat.getIntegerInstance().format(12345)} people", c("saved", 12345))
        assertEquals("Rebuild stopped. Showing your last saved web.", c("stopped"))
        assertEquals("Rebuild stopped. Showing your last saved web.", c(""))
    }

    @Test fun `a running rebuild's caption counts the seconds`() {
        val running = WotRefreshProgress(running = true, phase = "counting")
        assertEquals("Counting who your web trusts… · 42s", running.caption(42))
        val saved = WotRefreshProgress(running = false, phase = "saved", size = 7)
        assertEquals("Your web: 7 people", saved.caption(42))
    }

    @Test fun `missing numbers default to zero`() {
        val p = WotRefreshProgress.parse("""{"running":false,"phase":"saved"}""")!!
        assertFalse(p.running)
        assertEquals(0, p.size)
        assertEquals(1.0, p.fraction(0.0), 1e-9)
    }

    @Test fun `garbage is null`() {
        assertNull(WotRefreshProgress.parse(null))
        assertNull(WotRefreshProgress.parse(""))
        assertNull(WotRefreshProgress.parse("not json"))
        assertNull(WotRefreshProgress.parse("[1,2]"))
        assertNull(WotRefreshProgress.parse("\"running\""))
        assertNull(WotRefreshProgress.parse("""{"phase":"lists"}"""))
        assertNull(WotRefreshProgress.parse("""{"running":"yes","phase":"lists"}"""))
        assertNull(WotRefreshProgress.parse("""{"running":true,"phase":3}"""))
        assertNull(WotRefreshProgress.parse("""{"running":true,"phase":{"a":1}}"""))
        assertNull(WotRefreshProgress.parse("""{"running":true,"phase":"lists""""))
    }
}
