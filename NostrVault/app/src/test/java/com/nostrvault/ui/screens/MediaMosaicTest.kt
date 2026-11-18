package com.nostrvault.ui.screens

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Vault › Media as a mosaic (MediaMosaic.kt): Apple's MediaMosaicLayout rules
 * (PR #2193) and the web's (#2204). Shapes clamped to 1:2 … 2:1, square when
 * unknown; columns by width; EXIF rotation counted; learned shapes kept by hash,
 * read once per visit, written in batches, capped.
 */
class MediaMosaicTest {
    private fun hex(c: Char) = c.toString().repeat(64)

    @Test fun `shapes are clamped and unknown is square`() {
        assertEquals(2f, MediaMosaicLayout.clampedAspect(5f), 0f)
        assertEquals(0.5f, MediaMosaicLayout.clampedAspect(0.1f), 0f)
        assertEquals(1.5f, MediaMosaicLayout.clampedAspect(1.5f), 0f)
        for (bad in listOf(null, 0f, -1f, Float.NaN, Float.POSITIVE_INFINITY)) assertEquals(1f, MediaMosaicLayout.clampedAspect(bad), 0f)
    }

    @Test fun `three columns on a phone, more on a fold or tablet, at most six`() {
        assertEquals(listOf(3, 3, 3, 4, 4, 5, 5, 6, 6), listOf(320f, 411f, 599f, 600f, 899f, 900f, 1199f, 1200f, 2400f).map(MediaMosaicLayout::columnsFor))
    }

    @Test fun `EXIF orientations 5 to 8 turn the shape a quarter`() {
        assertEquals(4000f / 3000f, MediaMosaicLayout.shownAspect(4000, 3000, 1)!!, 0f)
        assertEquals(3000f / 4000f, MediaMosaicLayout.shownAspect(4000, 3000, 6)!!, 0f)
        assertEquals(3000f / 4000f, MediaMosaicLayout.shownAspect(4000, 3000, 8)!!, 0f)
        assertNull(MediaMosaicLayout.shownAspect(0, 3000, 1))
    }

    private class Store {
        var text: String? = null
        val queued = mutableListOf<Runnable>()
        val sizes = MediaMosaicSizes(read = { text }, write = { text = it }, schedule = { queued.add(it) })
    }

    @Test fun `learned shapes are written in one batch and read by the next grid`() {
        val s = Store()
        s.sizes.learn(hex('a'), 400f, 300f)
        s.sizes.learn("not-a-hash", 400f, 300f)
        s.sizes.learn(hex('b'), 0f, 300f)
        s.sizes.learn(hex('c'), 300f, 600f)
        assertEquals("one write scheduled for the batch", 1, s.queued.size)
        assertNull("nothing written yet", s.text)
        assertEquals(1.333f, s.sizes.snapshot()[hex('a')]!!, 0f) // waiting ones count for the next grid
        s.queued.removeAt(0).run()
        assertEquals(mapOf(hex('a') to 1.333f, hex('c') to 0.5f), s.sizes.snapshot())
        s.sizes.learn(hex('d'), 1f, 1f)
        assertEquals("a new batch after a write", 1, s.queued.size)
    }

    @Test fun `the store keeps the newest three thousand and reads past junk`() {
        val s = Store()
        for (i in 0 until MediaMosaicSizes.CAP + 5) s.sizes.learn(i.toString(16).padStart(64, '0'), 2f, 1f)
        s.sizes.flush()
        val kept = s.sizes.snapshot()
        assertEquals(MediaMosaicSizes.CAP, kept.size)
        assertTrue("the oldest went", (0 until 5).none { kept.containsKey(it.toString(16).padStart(64, '0')) })
        s.text = "junk\n${hex('e')} 1.5\n${hex('f')} -1\nnothex 2"
        assertEquals(mapOf(hex('e') to 1.5f), s.sizes.snapshot())
    }
}
