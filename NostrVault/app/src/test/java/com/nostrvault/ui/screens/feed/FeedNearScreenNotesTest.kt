package com.nostrvault.ui.screens.feed

import com.nostrvault.data.model.FeedNote
import org.junit.Assert.assertEquals
import org.junit.Test

class FeedNearScreenNotesTest {
    private fun hex(c: Char) = c.toString().repeat(64)
    private fun note(id: Char, tags: List<List<String>> = emptyList(), kind: Int = 1, content: String = "hi") =
        FeedNote.fromEvent(hex(id), hex('f'), content, tags, 1_000L, kind)

    @Test
    fun aRowsQuoteParentAndRepostOriginalAreAllAskedFor() {
        // The body's nostr:note1/nevent1 link is what makes a quote; set here directly.
        val quoting = note('1').copy(quotedEventIds = listOf(hex('a')))
        val reply = note('2', listOf(listOf("e", hex('b'), "", "reply")))
        val repost = note('3', listOf(listOf("e", hex('c')), listOf("p", hex('d'))), kind = 6, content = "")
        val plain = note('4')
        val refs = nearScreenReferences(listOf(quoting, reply, repost, plain))
        assertEquals(listOf(hex('a')), refs.quotes)
        assertEquals(listOf(hex('b'), hex('c')), refs.others)
    }

    @Test
    fun rowsWithNothingToLookUpAskForNothing() {
        assertEquals(NearScreenReferences(emptyList(), emptyList()), nearScreenReferences(listOf(note('4'))))
    }
}
