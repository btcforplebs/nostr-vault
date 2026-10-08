package com.nostrvault.data.model

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Writing a poll: what makes a draft postable, and the NIP-88 tags it becomes,
 * read back through the same parser the feed uses. Mirrors PollDraftTests.swift.
 */
class PollDraftTest {
    private val now = 1_800_000_000L

    private fun draft(question: String = "Ship it?", options: List<String> = listOf("Yes", "No")) =
        PollDraft(question = question, options = options)

    @Test fun needsAQuestionAndTwoDifferentOptions() {
        assertTrue(draft().isComplete(now))
        assertFalse(draft("  ").isComplete(now))
        assertFalse(draft("Q", listOf("Yes", " ")).isComplete(now))
        assertFalse(draft("Q", listOf("Yes", "yes ")).isComplete(now))
        assertTrue(draft("Q", listOf("Yes", "", "No")).isComplete(now))
        assertFalse(draft("Q", (1..11).map { "o$it" }).isComplete(now))
    }

    @Test fun endTimeMustBeAhead() {
        assertFalse(draft().copy(endsAt = now - 1).isComplete(now))
        assertTrue(draft().copy(endsAt = now + 3600).isComplete(now))
    }

    @Test fun tagsRoundTripThroughTheParser() {
        val d = draft(" Ship it? ", listOf("Yes", "", " No ")).copy(
            type = NIP88Poll.PollType.MULTIPLE, endsAt = 1_800_003_600L)
        val ids = listOf("aaa", "aaa", "bbb").iterator()
        val tags = d.tags(listOf("wss://relay.one", "WSS://RELAY.ONE", "ws://localhost:4869", "wss://relay.two")) { ids.next() }
        assertEquals(listOf(
            listOf("option", "aaa", "Yes"), listOf("option", "bbb", "No"),
            listOf("relay", "wss://relay.one"), listOf("relay", "wss://relay.two"),
            listOf("polltype", "multiplechoice"), listOf("endsAt", "1800003600"),
        ), tags)
        val poll = NIP88Poll.Poll.from("x", "y", 1068, d.trimmedQuestion, tags)!!
        assertEquals("Ship it?", poll.question)
        assertEquals(listOf("Yes", "No"), poll.options.map { it.label })
        assertEquals(NIP88Poll.PollType.MULTIPLE, poll.type)
        assertEquals(listOf("wss://relay.one", "wss://relay.two"), poll.relays)
    }

    @Test fun singleChoiceWithNoEndAndCappedRelays() {
        val tags = draft().tags((1..6).map { "wss://r$it.example" })
        assertEquals(PollDraft.MAX_RELAYS, tags.count { it[0] == "relay" })
        assertTrue(listOf("polltype", "singlechoice") in tags)
        assertFalse(tags.any { it[0] == "endsAt" })
        val ids = tags.filter { it[0] == "option" }.map { it[1] }
        assertEquals(2, ids.toSet().size)
        assertTrue(ids.all { id -> id.length == 9 && id.all { it.isLetterOrDigit() } })
    }

    @Test fun statusFilter() {
        fun p(ends: String?) = NIP88Poll.Poll.from("a", "b", 1068, "q",
            listOfNotNull(listOf("option", "1", "A"), ends?.let { listOf("endsAt", it) }))!!
        val polls = listOf(p("1800000100"), p("1799999900"), p(null))
        assertEquals(listOf(true, false, true), polls.map { PollStatusFilter.OPEN.admits(it, now) })
        assertEquals(listOf(false, true, false), polls.map { PollStatusFilter.CLOSED.admits(it, now) })
        assertEquals(listOf(true, true, true), polls.map { PollStatusFilter.ALL.admits(it, now) })
    }
}
