package com.nostrvault.data.model

import com.nostrvault.relay.HavenBridge
import com.nostrvault.ui.screens.pastedNotes
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * A note1 / nevent pasted into the composer is a quote: the Preview finds it
 * and the post carries `q` + the author's `p` (Logen GO 2026-11-01, 3.1.0).
 */
class QuoteRefPastedTest {
    private val id = "a".repeat(64)
    private val other = "d".repeat(64)
    private val author = "b".repeat(64)
    private val loadedAuthor = "c".repeat(64)

    private val note1 = HavenBridge.hexToNote1(id)!!
    private val nevent = HavenBridge.encodeNevent(other, author, 1)!!

    @Test fun `bare and prefixed note1 and nevent are all found`() {
        for (text in listOf("look $note1", "look nostr:$note1", "$note1\n")) {
            assertEquals(text, listOf(QuoteRef.EventPointer(id, null)), pastedNotes(text))
        }
        assertEquals(listOf(QuoteRef.EventPointer(other, author)), pastedNotes("see $nevent"))
        assertEquals(listOf(QuoteRef.EventPointer(other, author)), pastedNotes("see nostr:$nevent"))
    }

    @Test fun `the same note twice is one quote, in order`() {
        assertEquals(
            listOf(id, other),
            pastedNotes("nostr:$note1 $nevent $note1 nostr:$nevent").map { it.id },
        )
    }

    @Test fun `text, urls, profiles and a broken checksum are not quotes`() {
        val npub = HavenBridge.encodeNpub(author)!!
        val broken = note1.dropLast(1) + if (note1.last() == 'q') 'p' else 'q'
        assertTrue(pastedNotes("note1st draft, $npub, https://njump.me/$note1, $broken").isEmpty())
    }

    @Test fun `q carries the author and the author gets a p`() {
        val tags = QuoteRef.pastedQuoteTags(pastedNotes("x $nevent"), emptyList()) { null }
        assertEquals(listOf(listOf("q", other, "", author), listOf("p", author)), tags)
    }

    @Test fun `a loaded note's author beats the nevent and a note1 uses it`() {
        val tags = QuoteRef.pastedQuoteTags(pastedNotes("$note1 $nevent"), emptyList()) { loadedAuthor }
        assertEquals(
            listOf(
                listOf("q", id, "", loadedAuthor), listOf("p", loadedAuthor),
                listOf("q", other, "", loadedAuthor),
            ),
            tags,
        )
    }

    @Test fun `an unknown note1 author still posts the q tag`() {
        val tags = QuoteRef.pastedQuoteTags(pastedNotes(note1), emptyList()) { null }
        assertEquals(listOf(listOf("q", id, "", "")), tags)
    }

    @Test fun `nothing the post already tags is added twice`() {
        val existing = listOf(listOf("q", id, "", author), listOf("p", author))
        val tags = QuoteRef.pastedQuoteTags(pastedNotes("$note1 $nevent"), existing) { null }
        assertEquals(listOf(listOf("q", other, "", author)), tags)
    }
}
