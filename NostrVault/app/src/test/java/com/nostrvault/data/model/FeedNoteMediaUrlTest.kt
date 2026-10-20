package com.nostrvault.data.model

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/** The Media grid drew njump.me links as broken images. Mirrors iOS SupportedMediaFormatsTests. */
class FeedNoteMediaUrlTest {
    private fun urls(text: String) = FeedNote.parseMediaURLs(text)

    @Test
    fun `nostr web client hex links are not media`() {
        // Shape of real notes: njump.me serves the event page at /<event id>.
        val id = "84abd19a647d5aab47010926d258d0294e108727495df5de996f5baab3c8949a"
        assertEquals(emptyList<String>(), urls("read https://njump.me/$id"))
        assertEquals(emptyList<String>(), urls("https://www.primal.net/$id"))
        assertFalse(FeedNote.isMediaUrl("https://njump.me/$id"))
        // A real Blossom server under a gateway's domain still counts.
        assertEquals(listOf("https://blossom.primal.net/$id"), urls("https://blossom.primal.net/$id"))
        assertEquals(listOf("https://cdn.example.com/$id"), urls("https://cdn.example.com/$id"))
    }

    @Test
    fun `bech32 web links are not media`() {
        val text = "https://njump.me/nevent1qqsxyz https://njump.me/note1abc https://njump.me/naddr1qq https://njump.me/npub1abc.rss"
        assertEquals(emptyList<String>(), urls(text))
    }

    @Test
    fun `extension must end the url`() {
        assertEquals(emptyList<String>(), urls("https://www.avid.com/x"))
        assertEquals(emptyList<String>(), urls("https://blog.pngtree.com/p"))
        assertEquals(emptyList<String>(), urls("https://njump.me/naddr1qq.mp4ish"))
        assertEquals(emptyList<String>(), urls("https://example.mov"))
        assertEquals(listOf("https://www.avid.com/clip.mp4"), urls("https://www.avid.com/clip.mp4"))
        assertEquals(listOf("https://x.com/a.JPG"), urls("look https://x.com/a.JPG."))
        assertEquals(listOf("https://x.com/a.png"), urls("(https://x.com/a.png)"))
        assertEquals(listOf("https://x.com/a.jpg?w=1"), urls("https://x.com/a.jpg?w=1"))
        assertEquals(listOf("https://x.com/a.jpg-thumb.webp"), urls("https://x.com/a.jpg-thumb.webp"))
        assertEquals(listOf("https://image.nostr.build/a.jpg"), urls("https://image.nostr.build/a.jpg https://njump.me/note1abc"))
    }

    @Test
    fun `imeta keeps uploads and drops web pages`() {
        val id = "a".repeat(64)
        assertTrue(FeedNote.isImetaMediaUrl("https://cdn.example.com/upload"))
        assertTrue(FeedNote.isImetaMediaUrl("https://njump.me/a.png"))
        assertFalse(FeedNote.isImetaMediaUrl("https://njump.me/$id"))
        val note = FeedNote(
            id = "1", pubkey = "p", content = "", createdAt = java.util.Date(0),
            tags = listOf(listOf("imeta", "url https://njump.me/$id"), listOf("imeta", "url https://cdn.example.com/up")),
            kind = 1,
        )
        assertEquals(listOf("https://cdn.example.com/up"), note.mediaURLs)
    }
}
