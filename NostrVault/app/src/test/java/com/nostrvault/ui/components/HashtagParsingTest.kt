package com.nostrvault.ui.components

import com.nostrvault.ui.navigation.HashtagLink
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

/**
 * Which `#…` in a note opens a hashtag feed, and which stays plain text (iOS
 * #173 parity: URL fragments, markdown and "#123" are left alone).
 */
class HashtagParsingTest {

    /** The tags a note's hashtag segments link to, in order. */
    private fun tags(content: String): List<String> =
        parseContentSegments(content, emptySet()).filterIsInstance<ContentSegment.Hashtag>().map { it.tag }

    @Test
    fun `a hashtag links to its lowercased tag`() {
        assertEquals(listOf("bitcoin"), tags("Stacking #Bitcoin today"))
        val seg = parseContentSegments("#Nostr", emptySet()).single() as ContentSegment.Hashtag
        assertEquals("#Nostr", seg.text)
        assertEquals("nostr", seg.tag)
    }

    @Test
    fun `punctuation after a hashtag ends it`() {
        assertEquals(listOf("bitcoin", "nostr"), tags("Love #bitcoin, and #nostr."))
        assertEquals(listOf("zap"), tags("(#zap)"))
    }

    @Test
    fun `start, end and line breaks`() {
        assertEquals(listOf("gm", "pv"), tags("#gm\nfriends #pv"))
    }

    @Test
    fun `letters beyond ascii and underscores`() {
        assertEquals(listOf("café", "日本", "plebs_unite"), tags("#café #日本 #plebs_unite"))
    }

    @Test
    fun `numbers alone stay plain`() {
        assertEquals(emptyList<String>(), tags("Fixed in #123"))
        assertEquals(listOf("21m"), tags("Only #21M"))
    }

    @Test
    fun `a URL fragment stays part of the URL`() {
        val url = "https://example.com/page#section"
        val segments = parseContentSegments("see $url", emptySet())
        assertEquals(emptyList<String>(), segments.filterIsInstance<ContentSegment.Hashtag>())
        assertEquals(url, segments.filterIsInstance<ContentSegment.Url>().single().url)
    }

    @Test
    fun `mid-word, entities, markdown labels and doubled hashes stay plain`() {
        assertEquals(emptyList<String>(), tags("C#sharp a/#b &#39; [#label](x) ##double"))
    }

    @Test
    fun `search query names a hashtag only when it is one tag`() {
        assertEquals("bitcoin", HashtagLink.fromSearchQuery("  #Bitcoin "))
        assertNull(HashtagLink.fromSearchQuery("#b"))
        assertNull(HashtagLink.fromSearchQuery("#bitcoin nostr"))
        assertNull(HashtagLink.fromSearchQuery("#a#b"))
        assertNull(HashtagLink.fromSearchQuery("bitcoin"))
    }

    @Test
    fun `normalize strips hashes and lowercases`() {
        assertEquals("nostr", HashtagLink.normalize("##Nostr"))
        assertNull(HashtagLink.normalize("#"))
        assertNull(HashtagLink.normalize(""))
    }
}
