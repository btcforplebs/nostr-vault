package com.nostrvault.ui.components

import com.nostrvault.data.model.FeedNote
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * #170 parity: every link leaves the note text and gets its own card, so the
 * text must close the gap each one leaves and the card list must name each
 * link once. No `nostr:npub…` here: resolving one needs the native library.
 */
class HideLinksInTextTest {

    private val video = "https://logen.btcforplebs.com/40051f70189f48d34b72b975273cc4f0b6da4a60f577da3598f67232b38d4a48.mp4"

    private fun shown(content: String, stripped: Set<String>): String =
        parseContentSegments(content, stripped).joinToString("") {
            when (it) {
                is ContentSegment.PlainText -> it.text
                is ContentSegment.Url -> "<${it.url}>"
                is ContentSegment.Hashtag -> it.text
                else -> ""
            }
        }

    @Test
    fun `a link mid-sentence leaves one space`() {
        val url = "https://example.com/post"
        assertEquals("read now", shown("read $url now", setOf(url)))
        assertEquals("read now", shown("read  $url  now", setOf(url)))
    }

    @Test
    fun `trailing punctuation stays after the link goes`() {
        val url = "https://example.com/a"
        // The regex leaves the full stop out of the URL, so it is kept (as iOS).
        assertEquals("see .", shown("see $url.", setOf(url)))
    }

    @Test
    fun `a note that is only a link renders nothing`() {
        val url = "https://example.com/a"
        assertEquals("", shown("  $url \n", setOf(url)))
    }

    @Test
    fun `a link not handed in stays tappable`() {
        val url = "https://example.com/a"
        assertEquals("go <$url> now", shown("go $url now", emptySet()))
    }

    @Test
    fun `hashtags beside a removed link survive`() {
        val url = "https://example.com/a"
        assertEquals("#nostr rocks", shown("#nostr $url rocks", setOf(url)))
    }

    @Test
    fun `longest url goes first so a prefix cannot cut into it`() {
        val short = "https://a.com"
        val long = "https://a.com/page"
        assertEquals("x y", NostrMentions.stripUrls("x $long y", listOf(short, long)))
    }

    @Test
    fun `plain text strips links and media and closes gaps`() {
        val url = "https://example.com/a"
        val text = NostrMentions.toPlainText("look $url at $video this", emptyMap(), setOf(video), setOf(url))
        assertEquals("look at this", text)
    }

    @Test
    fun `newlines are kept when gaps close`() {
        assertEquals("a\n b", NostrMentions.stripUrls("a\nhttps://x.com/q b", listOf("https://x.com/q")))
    }

    @Test
    fun `each link is listed once and media is not a link`() {
        val content = "https://a.com/x and $video and https://a.com/x again https://wavlake.com/track/abc"
        val media = FeedNote.parseMediaURLs(content).toSet()
        val links = FeedNote.parseLinkURLs(content, media)
        assertEquals(listOf("https://a.com/x", "https://wavlake.com/track/abc"), links)
        assertTrue(video in media)
        assertFalse(video in links)
    }

    @Test
    fun `a note with hundreds of links gets three cards and keeps the rest in the text`() {
        // Each card fetches its page; 500 links to the poster's own host must
        // not become 500 requests from the phone (Tron, #183).
        val links = (1..500).map { "https://attacker.example/p$it" }
        val note = FeedNote(
            id = "a".repeat(64), pubkey = "b".repeat(64), content = links.joinToString(" "),
            createdAt = java.util.Date(0), tags = emptyList(), kind = 1,
        )
        assertEquals(500, note.linkURLs.size)
        assertEquals(links.take(FeedNote.MAX_LINK_CARDS), note.cardLinkURLs)

        val segments = parseContentSegments(note.content, note.cardLinkURLs.toSet())
        val tappable = segments.filterIsInstance<ContentSegment.Url>().map { it.url }
        assertEquals(links.drop(FeedNote.MAX_LINK_CARDS), tappable)
    }

    @Test
    fun `domain drops www`() {
        assertEquals("example.com", linkDomain("https://www.example.com/a?b=c"))
    }
}
