package com.nostrvault.ui.components

import org.junit.Assert.assertEquals
import org.junit.Assert.assertSame
import org.junit.Test

class CachedContentSegmentsTest {

    @Test
    fun sameTextReturnsTheSameParse() {
        val text = "see https://example.com/a #nostr"
        val first = cachedContentSegments(text, emptySet())
        assertSame(first, cachedContentSegments(text, emptySet()))
        assertEquals(parseContentSegments(text, emptySet()), first)
    }

    @Test
    fun strippedUrlsArePartOfTheKey() {
        val url = "https://example.com/pic.jpg"
        val text = "look $url"
        val kept = cachedContentSegments(text, emptySet())
        val stripped = cachedContentSegments(text, setOf(url))
        assertEquals(parseContentSegments(text, emptySet()), kept)
        assertEquals(parseContentSegments(text, setOf(url)), stripped)
    }
}
