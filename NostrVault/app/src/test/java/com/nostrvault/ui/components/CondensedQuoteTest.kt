package com.nostrvault.ui.components

import com.nostrvault.data.model.FeedNote
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.util.Date

class CondensedQuoteTest {

    private val quotedId = "c".repeat(64)
    private val otherId = "e".repeat(64)

    private fun note(
        id: String,
        kind: Int = 1,
        tags: List<List<String>> = emptyList(),
        content: String = "x",
        quotes: List<String> = emptyList(),
    ) = FeedNote(id = id, pubkey = "a".repeat(64), content = content, createdAt = Date(0), tags = tags, kind = kind)
        .copy(quotedEventIds = quotes)

    private val quoted = note(quotedId, content = "the quoted note")

    @Test fun aNoteWithoutQuotesHasNone() =
        assertTrue(CondensedQuote.resolve(note("n1")) { quoted }.isEmpty())

    @Test fun eachQuoteIsTheNoteOnceItHasArrived() {
        val quoting = note("n1", quotes = listOf(quotedId, otherId))
        val quotes = CondensedQuote.resolve(quoting) { id -> quoted.takeIf { id == quotedId } }
        assertEquals(listOf(quotedId, otherId), quotes.map { it.id })
        assertEquals(quoted, quotes[0].note)
        assertNull("still on its way: drawn as a placeholder", quotes[1].note)
    }

    @Test fun aQuoteNamedTwiceDrawsOnce() =
        assertEquals(1, CondensedQuote.resolve(note("n1", quotes = listOf(quotedId, quotedId))) { quoted }.size)

    @Test fun aResolvedBareRepostShowsItsOriginalsQuotes() {
        val bare = note("r1", kind = 6, tags = listOf(listOf("e", "b".repeat(64))), content = "")
        assertTrue("still loading: nothing quoted yet", CondensedQuote.resolve(bare) { quoted }.isEmpty())
        val original = note("b".repeat(64), quotes = listOf(quotedId))
        val shown = bare.withRepostedOriginal(original)
        assertEquals(listOf(CondensedQuote(quotedId, quoted)), CondensedQuote.resolve(shown) { quoted })
    }
}
