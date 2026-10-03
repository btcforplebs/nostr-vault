package com.nostrvault.data.model

import com.nostrvault.ui.components.NostrMentions
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * [NostrMentions.toPlainText] is the condensed renderer used by preview cards.
 * These pin what it removes, so it cannot drift from the full renderer again —
 * the quoted card was printing a raw `.mp4` URL directly above the video it
 * described, because only the full renderer stripped media.
 *
 * No `nostr:npub…` appears in these fixtures on purpose: resolving one needs
 * bech32 from the native library, and nothing here should require a device.
 */
class NostrMentionsTest {

    private val video = "https://logen.btcforplebs.com/40051f70189f48d34b72b975273cc4f0b6da4a60f577da3598f67232b38d4a48.mp4"

    @Test
    fun `a media url the caller renders is dropped from the text`() {
        val text = NostrMentions.toPlainText("look at this $video", emptyMap(), setOf(video))
        assertEquals("look at this", text)
    }

    @Test
    fun `a media url is kept when the caller does not render it`() {
        // Preview rows that draw no thumbnail keep the link: it is the only
        // sign the note carries media at all.
        val text = NostrMentions.toPlainText("look at this $video", emptyMap())
        assertTrue(text.contains(video))
    }

    @Test
    fun `a url that is not the rendered media survives`() {
        val article = "https://example.com/post"
        val text = NostrMentions.toPlainText("read $article and see $video", emptyMap(), setOf(video))
        assertTrue(text.contains(article))
        assertTrue(!text.contains(video))
    }

    @Test
    fun `several rendered media urls all go`() {
        val second = "https://example.com/b.png"
        val text = NostrMentions.toPlainText("$video and $second", emptyMap(), setOf(video, second))
        assertEquals("and", text)
    }

    @Test
    fun `quote references are still stripped`() {
        val text = NostrMentions.toPlainText("see nostr:nevent1abc for more", emptyMap())
        // The gap closes to one space, as iOS does since #170.
        assertEquals("see for more", text)
    }

    @Test
    fun `a note that is only its media url renders as nothing`() {
        // The card must then draw no text block at all rather than an empty line.
        assertEquals("", NostrMentions.toPlainText(video, emptyMap(), setOf(video)))
    }
}
