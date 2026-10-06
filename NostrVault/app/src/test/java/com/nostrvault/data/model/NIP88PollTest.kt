package com.nostrvault.data.model

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.util.UUID

/**
 * NIP-88 polls: read from a kind 1068, counted from kind 1018 votes with one
 * vote per person, only real options, nothing after the poll closes. Mirrors
 * HavenApp/MediaLogicTests/Tests/MediaLogicTests/NIP88PollTests.swift — if a
 * rule changes on one platform it should fail here too.
 */
class NIP88PollTest {
    private val pollId = "a".repeat(64)
    private val author = "b".repeat(64)
    private val now = 1_800_000_000L

    private fun poll(type: String? = null, endsAt: Long? = null, relays: List<String> = emptyList()): NIP88Poll.Poll {
        val tags = mutableListOf(listOf("option", "yes", "Yes"), listOf("option", "no", "No"), listOf("option", "idk", "Not sure"))
        type?.let { tags.add(listOf("polltype", it)) }
        endsAt?.let { tags.add(listOf("endsAt", it.toString())) }
        tags += relays.map { listOf("relay", it) }
        return NIP88Poll.Poll.from(pollId, author, 1068, " Ship it? ", tags)!!
    }

    private fun vote(
        voter: Char,
        picks: List<String>,
        at: Long = -60,
        id: String? = null,
        pollRef: String? = null,
        kind: Int = 1018,
    ) = NIP88Poll.Response(
        id = id ?: UUID.randomUUID().toString(),
        pubkey = voter.toString().repeat(64),
        kind = kind,
        createdAt = now + at,
        tags = listOf(listOf("e", pollRef ?: pollId)) + picks.map { listOf("response", it) },
    )

    // Reading a poll

    @Test fun readsQuestionOptionsTypeEndAndRelays() {
        val p = poll(type = "multiplechoice", endsAt = 1_900_000_000, relays = listOf("wss://relay.one"))
        assertEquals("Ship it?", p.question)
        assertEquals(listOf("yes", "no", "idk"), p.options.map { it.id })
        assertEquals(listOf("Yes", "No", "Not sure"), p.options.map { it.label })
        assertEquals(NIP88Poll.PollType.MULTIPLE, p.type)
        assertEquals(1_900_000_000L, p.endsAt)
        assertEquals(listOf("wss://relay.one"), p.relays)
    }

    @Test fun defaultsToSingleChoiceAndNoEnd() {
        val p = poll()
        assertEquals(NIP88Poll.PollType.SINGLE, p.type)
        assertNull(p.endsAt)
        assertFalse(p.isClosed(now))
    }

    @Test fun rejectsOtherKindsAndPollsWithoutOptions() {
        assertNull(NIP88Poll.Poll.from(pollId, author, 1, "q", listOf(listOf("option", "a", "A"))))
        assertNull(NIP88Poll.Poll.from(pollId, author, 1068, "q", listOf(listOf("option", "a", " "))))
    }

    @Test fun duplicateOptionIdsKeepTheFirst() {
        val p = NIP88Poll.Poll.from(pollId, author, 1068, "q", listOf(listOf("option", "a", "First"), listOf("option", "a", "Second")))
        assertEquals(listOf(NIP88Poll.Option("a", "First")), p?.options)
    }

    @Test fun closedOnceEndsAtPasses() {
        assertTrue(poll(endsAt = now - 1).isClosed(now))
        assertFalse(poll(endsAt = now + 60).isClosed(now))
    }

    // Counting

    @Test fun countsOneVotePerPersonNewestWins() {
        val t = NIP88Poll.tally(listOf(vote('c', listOf("yes"), at = -300), vote('c', listOf("no"), at = -10), vote('d', listOf("no"))), poll(), now)
        assertEquals(2, t.voters.size)
        assertEquals(0, t.count("yes"))
        assertEquals(2, t.count("no"))
        assertEquals(1.0, t.share("no"), 0.0)
    }

    @Test fun sameSecondTieIsDecidedTheSameWayEverywhere() {
        val a = vote('c', listOf("yes"), at = -10, id = "1")
        val b = vote('c', listOf("no"), at = -10, id = "2")
        assertEquals(listOf("yes"), NIP88Poll.tally(listOf(a, b), poll(), now).picksByVoter.values.first())
        assertEquals(listOf("yes"), NIP88Poll.tally(listOf(b, a), poll(), now).picksByVoter.values.first())
    }

    @Test fun singleChoiceCountsOnlyTheFirstPick() {
        val t = NIP88Poll.tally(listOf(vote('c', listOf("no", "yes"))), poll(), now)
        assertEquals(1, t.count("no"))
        assertEquals(0, t.count("yes"))
    }

    @Test fun multipleChoiceCountsEachPickOnce() {
        val t = NIP88Poll.tally(listOf(vote('c', listOf("no", "yes", "no")), vote('d', listOf("yes"))), poll(type = "multiplechoice"), now)
        assertEquals(2, t.voters.size)
        assertEquals(2, t.count("yes"))
        assertEquals(1, t.count("no"))
        assertEquals(0.5, t.share("no"), 0.0)
    }

    @Test fun ignoresUnknownOptionsOtherPollsAndOtherKinds() {
        val t = NIP88Poll.tally(
            listOf(
                vote('c', listOf("maybe")),
                vote('d', listOf("yes"), pollRef = "f".repeat(64)),
                vote('e', listOf("yes"), kind = 7),
            ),
            poll(), now,
        )
        assertTrue(t.voters.isEmpty())
    }

    @Test fun aNewerVoteWithNoRealPicksWithdrawsTheEarlierOne() {
        // Newest wins, and the newest said nothing countable: that person
        // has withdrawn, as other clients count it.
        val t = NIP88Poll.tally(listOf(vote('c', listOf("yes"), at = -300), vote('c', listOf("maybe"), at = -10)), poll(), now)
        assertTrue(t.voters.isEmpty())
    }

    @Test fun votesAfterThePollClosesDoNotCount() {
        val p = poll(endsAt = now - 100)
        val t = NIP88Poll.tally(
            listOf(vote('c', listOf("yes"), at = -200), vote('c', listOf("no"), at = -50), vote('d', listOf("no"), at = -50)),
            p, now,
        )
        assertEquals(1, t.voters.size)
        assertEquals(listOf("yes"), t.picksByVoter["c".repeat(64)])
    }

    @Test fun futureDatedVotesDoNotPinAPick() {
        val t = NIP88Poll.tally(listOf(vote('c', listOf("yes"), at = -60), vote('c', listOf("no"), at = 86_400)), poll(), now)
        assertEquals(listOf("yes"), t.picksByVoter["c".repeat(64)])
    }

    @Test fun noVotesShareIsZero() {
        assertEquals(0.0, PollTally().share("yes"), 0.0)
    }

    // Voting

    @Test fun voteTagsNameThePollAndOnlyRealPicks() {
        val tags = NIP88Poll.responseTags(poll(), listOf("no", "yes", "bogus"), relayHint = "wss://r")
        assertEquals(listOf(listOf("e", pollId, "wss://r"), listOf("p", author), listOf("response", "no")), tags)
        val multi = NIP88Poll.responseTags(poll(type = "multiplechoice"), listOf("no", "yes", "no"), relayHint = "")
        assertEquals(listOf(listOf("response", "no"), listOf("response", "yes")), multi.filter { it[0] == "response" })
    }

    @Test fun filterAsksForVotesOnThisPoll() {
        assertEquals("""{"kinds":[1018],"#e":["$pollId"],"limit":1000}""", NIP88Poll.responseFilter(pollId))
    }

    @Test fun relaysPutThePollsOwnFirstAndDropDuplicates() {
        val p = poll(relays = listOf("wss://poll.relay/", "https://not-a-relay"))
        val r = NIP88Poll.relays(p, fallback = listOf("wss://poll.relay", "wss://feed.relay"))
        assertEquals(listOf("wss://poll.relay/", "wss://feed.relay"), r)
    }

    @Test fun relaysAreCapped() {
        val r = NIP88Poll.relays(poll(), fallback = (1..20).map { "wss://r$it.example" })
        assertEquals(NIP88Poll.MAX_RELAYS, r.size)
    }

    // Rows

    private fun note(kind: Int, content: String, tags: List<List<String>>) =
        FeedNote.fromEvent("n".repeat(64), author, content, tags, now, kind)

    @Test fun pollSummaryShowsTheQuestionOrTheOptions() {
        val options = listOf(listOf("option", "a", "Tea"), listOf("option", "b", "Coffee"))
        assertEquals("Poll: Tea or coffee?", note(1068, "Tea or coffee?", options).pollSummary)
        assertEquals("Poll: Tea / Coffee", note(1068, "", options).pollSummary)
        assertNull(note(1, "Tea or coffee?", options).pollSummary)
    }

    @Test fun pollOnANoteNeedsOptions() {
        assertNull(note(1068, "Nothing to pick", emptyList()).poll)
    }
}
