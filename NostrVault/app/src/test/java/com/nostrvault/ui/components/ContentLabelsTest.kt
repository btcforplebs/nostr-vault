package com.nostrvault.ui.components

import org.junit.Assert.assertEquals
import org.junit.Test

/** Link and mention labels in note text, as iOS NostrContentFormatter draws them. */
class ContentLabelsTest {

    @Test
    fun `a bare domain shows as the domain without www`() {
        assertEquals("example.com", linkDisplayLabel("https://www.example.com"))
        assertEquals("example.com", linkDisplayLabel("https://example.com/"))
    }

    @Test
    fun `a short path follows the domain`() {
        assertEquals("example.com/notes/1", linkDisplayLabel("https://example.com/notes/1"))
        assertEquals("example.com/notes", linkDisplayLabel("https://example.com/notes/"))
    }

    @Test
    fun `a long path is cut at twenty characters`() {
        assertEquals(
            "github.com/btcforplebs/nostr-v...",
            linkDisplayLabel("https://github.com/btcforplebs/nostr-vault/pull/1"),
        )
    }

    @Test
    fun `a url without a host shows as written`() {
        assertEquals("not a url", linkDisplayLabel("not a url"))
    }

    @Test
    fun `an unloaded mention shows the first twelve characters of its bech32`() {
        val npub = "npub1yl3j4ev3r0v92ljmv889c7etvlrpemfhs2d0dr4atxfpvsux6mfqt269tr"
        val seg = parseContentSegments("hi nostr:$npub", emptySet())
            .filterIsInstance<ContentSegment.Mention>().single()
        assertEquals("npub1yl3j4ev...", mentionFallbackLabel(seg))
    }

    @Test
    fun `a mention without its bech32 falls back to the hex`() {
        assertEquals("27e32ae5...", mentionFallbackLabel(ContentSegment.Mention("27e32ae5911bd855")))
    }
}
