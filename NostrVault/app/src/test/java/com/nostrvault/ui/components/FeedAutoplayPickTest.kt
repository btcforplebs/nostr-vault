package com.nostrvault.ui.components

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

/** One inline feed video plays at a time: the most visible, if visible enough. */
class FeedAutoplayPickTest {

    @Test fun `nothing on screen plays nothing`() {
        assertNull(pickAutoplay(emptyMap<String, Float>()))
    }

    @Test fun `a video mostly off screen does not start`() {
        assertNull(pickAutoplay(mapOf("a" to 0.5f)))
    }

    @Test fun `the most visible video wins`() {
        assertEquals("b", pickAutoplay(linkedMapOf("a" to 0.7f, "b" to 1f, "c" to 0.9f)))
    }

    @Test fun `a tie stays with the first reported`() {
        assertEquals("a", pickAutoplay(linkedMapOf("a" to 1f, "b" to 1f)))
    }

    @Test fun `threshold is inclusive`() {
        assertEquals("a", pickAutoplay(mapOf("a" to AUTOPLAY_MIN_VISIBLE)))
    }
}
