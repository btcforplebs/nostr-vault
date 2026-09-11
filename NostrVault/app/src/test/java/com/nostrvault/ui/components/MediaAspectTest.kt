package com.nostrvault.ui.components

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Before
import org.junit.Test

private const val URL = "https://blossom.example/photo.jpg"
private const val OTHER = "https://blossom.example/other.jpg"

class MediaAspectTest {

    @Before
    fun reset() = MediaAspectCache.clear()

    @Test
    fun `reads dim from the imeta tag for the matching url`() {
        val tags = listOf(listOf("imeta", "url $URL", "dim 3024x4032", "m image/jpeg"))
        assertEquals(3024f / 4032f, imetaAspectRatio(tags, URL)!!, 1e-6f)
    }

    @Test
    fun `a dim belonging to a different url is not used`() {
        // The failure this guards is the one that matters: a note with two
        // images would otherwise size the second from the first's dimensions.
        val tags = listOf(listOf("imeta", "url $OTHER", "dim 4032x3024"))
        assertNull(imetaAspectRatio(tags, URL))
    }

    @Test
    fun `picks the right imeta out of several`() {
        val tags = listOf(
            listOf("imeta", "url $OTHER", "dim 4032x3024"),
            listOf("imeta", "url $URL", "dim 1080x1920"),
        )
        assertEquals(1080f / 1920f, imetaAspectRatio(tags, URL)!!, 1e-6f)
    }

    @Test
    fun `an imeta with no dim yields nothing rather than a default`() {
        assertNull(imetaAspectRatio(listOf(listOf("imeta", "url $URL", "m image/jpeg")), URL))
    }

    @Test
    fun `malformed dims are ignored`() {
        for (dim in listOf("dim 3024", "dim x4032", "dim 0x100", "dim 100x0", "dim axb", "dim -3x4")) {
            assertNull(dim, imetaAspectRatio(listOf(listOf("imeta", "url $URL", dim)), URL))
        }
    }

    @Test
    fun `non-imeta tags are skipped`() {
        assertNull(imetaAspectRatio(listOf(listOf("e", "abc"), listOf("p"), emptyList()), URL))
    }

    @Test
    fun `the cache answers for a url decoded earlier`() {
        assertNull(knownAspectRatio(emptyList(), URL))
        MediaAspectCache.put(URL, 1.5f)
        assertEquals(1.5f, knownAspectRatio(emptyList(), URL)!!, 1e-6f)
    }

    @Test
    fun `imeta beats the cache`() {
        // A hint that changes after the decode lands would shift the feed a
        // second time, which is the whole thing this is here to stop.
        MediaAspectCache.put(URL, 1.5f)
        val tags = listOf(listOf("imeta", "url $URL", "dim 1000x1000"))
        assertEquals(1f, knownAspectRatio(tags, URL)!!, 1e-6f)
    }

    @Test
    fun `the cache refuses a nonsense ratio`() {
        MediaAspectCache.put(URL, 0f)
        MediaAspectCache.put(URL, Float.NaN)
        MediaAspectCache.put(URL, Float.POSITIVE_INFINITY)
        assertNull(MediaAspectCache.get(URL))
    }

    @Test
    fun `the cache is bounded and evicts least-recently-used`() {
        MediaAspectCache.put("keep", 1f)
        repeat(600) { MediaAspectCache.put("url$it", 1f) }
        // "keep" was touched first and never again, so it is gone; the newest
        // entries survive. Without a bound a long session grows without limit.
        assertNull(MediaAspectCache.get("keep"))
        assertEquals(1f, MediaAspectCache.get("url599")!!, 1e-6f)
    }
}
