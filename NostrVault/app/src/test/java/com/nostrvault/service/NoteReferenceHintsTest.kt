package com.nostrvault.service

import com.nostrvault.data.model.FeedNote
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class NoteReferenceHintsTest {

    private val parent = "p".repeat(64)
    private val author = "a".repeat(64)

    private fun note(id: String, tags: List<List<String>>) = FeedNote.fromEvent(
        id = id, pubkey = "b".repeat(64), content = "reply", tags = tags,
        createdAt = 1_700_000_000L, kind = 1,
    )

    @Test
    fun replyGivesItsRelayHintAndParentAuthor() {
        val reply = note("r", listOf(
            listOf("e", parent, "wss://relay.nostr.net", "reply", author),
            listOf("p", author),
        ))
        assertEquals("wss://relay.nostr.net" to author, NoteReferenceHints.find(parent, sequenceOf(reply)))
    }

    @Test
    fun noHintFallsBackToTheLastPTagOfADirectReply() {
        val reply = note("r", listOf(listOf("e", parent, "", "reply"), listOf("p", author)))
        assertEquals(null to author, NoteReferenceHints.find(parent, sequenceOf(reply)))
    }

    @Test
    fun aNoteOutsideTheFeedIsStillAsked() {
        // The thread page's opened reply lives in the parent cache, which the
        // lookup now scans after the feed: an unrelated feed note gives nothing.
        val unrelated = note("u", listOf(listOf("e", "x".repeat(64), "wss://other")))
        val opened = note("r", listOf(listOf("e", parent, "wss://relay.nostr.net", "reply", author)))
        assertEquals("wss://relay.nostr.net" to author, NoteReferenceHints.find(parent, sequenceOf(unrelated, opened)))
    }

    @Test
    fun nothingReferencesIt() {
        assertNull(NoteReferenceHints.find(parent, sequenceOf(note("u", emptyList()))))
    }
}
