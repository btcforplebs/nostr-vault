package com.nostrvault.ui.components

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Test

class BlurHashTest {

    // The reference hash from blurha.sh's README (a 4x3-component photo).
    private val reference = "LEHV6nWB2yk8pyo0adR*.7kCMdnj"

    @Test
    fun `decodes the reference hash to a full 32x32 opaque image`() {
        val pixels = BlurHash.decode(reference)
        assertNotNull(pixels)
        assertEquals(32 * 32, pixels!!.size)
        assert(pixels.all { it ushr 24 == 0xFF })
    }

    @Test
    fun `the top-left pixel carries the hash's average colour family`() {
        // DC of the reference is "HV6n" — a muted purple-grey. Not an exact
        // value (the AC terms move every pixel), but it must not be black,
        // white or saturated: that would mean the bit layout is wrong.
        val p = BlurHash.decode(reference)!![0]
        val r = (p shr 16) and 255; val g = (p shr 8) and 255; val b = p and 255
        assert(r in 60..220 && g in 60..220 && b in 60..220) { "rgb=$r,$g,$b" }
    }

    @Test
    fun `a hash whose length disagrees with its component count is rejected`() {
        assertNull(BlurHash.decode(reference.dropLast(1)))
    }

    @Test
    fun `characters outside the base83 alphabet are rejected`() {
        assertNull(BlurHash.decode("LEHV6nWB2yk8pyo0adR*.7kCMdn\""))
    }

    @Test
    fun `imeta blurhash is read for the matching url only`() {
        val tags = listOf(
            listOf("imeta", "url https://a/1.jpg", "blurhash $reference"),
            listOf("imeta", "url https://a/2.jpg", "dim 10x10"),
        )
        assertEquals(reference, imetaField(tags, "https://a/1.jpg", "blurhash"))
        assertNull(imetaField(tags, "https://a/2.jpg", "blurhash"))
    }
}
