package com.nostrvault.ui.components

import org.junit.Assert.assertEquals
import org.junit.Assert.assertSame
import org.junit.Test

/** Note text is parsed once, not again every time its row scrolls back in. */
class TextParseCacheTest {
    @Test
    fun `computes once per key and forgets the least recently used`() {
        val cache = TextParseCache<String, String>(2)
        var runs = 0
        fun get(k: String) = cache.getOrPut(k) { runs++; k.uppercase() }
        get("a"); get("a"); get("b")
        assertEquals(2, runs)
        get("a") // a is now the most recent
        get("c") // evicts b
        assertEquals(2, cache.size)
        get("a")
        assertEquals(3, runs)
        get("b")
        assertEquals(4, runs)
    }

    @Test
    fun `a row scrolling back in gets the same segments without a parse`() {
        val text = "gm #nostr https://example.com/x.jpg ${System.nanoTime()}"
        val stripped = setOf("https://example.com/x.jpg")
        val first = cachedContentSegments(text, stripped)
        assertEquals(parseContentSegments(text, stripped), first)
        assertSame(first, cachedContentSegments(text, stripped))
        // Another stripped set is another parse: the URL stays in the text.
        assertEquals(parseContentSegments(text, emptySet()), cachedContentSegments(text, emptySet()))
    }

    @Test
    fun `mentioned pubkeys are worked out once per text`() {
        val text = "hi ${System.nanoTime()}"
        assertSame(NostrMentions.mentionedPubkeys(text), NostrMentions.mentionedPubkeys(text))
    }
}
