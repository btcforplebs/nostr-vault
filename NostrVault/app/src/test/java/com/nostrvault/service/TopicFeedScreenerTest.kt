package com.nostrvault.service

import com.nostrvault.data.model.FeedNote
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.test.TestScope
import kotlinx.coroutines.test.advanceUntilIdle
import kotlinx.coroutines.test.runTest
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import java.util.Date

/** The pool, the lookups and the order the topic feed ends up in, against a fake relay. */
@OptIn(ExperimentalCoroutinesApi::class)
class TopicFeedScreenerTest {
    private fun note(id: String, pubkey: String, seconds: Long, content: String = "post $id") =
        FeedNote(id = id, pubkey = pubkey, content = content, createdAt = Date(seconds * 1000), tags = listOf(listOf("t", "nostr")), kind = 1)

    private fun event(json: String): JsonObject = Json.parseToJsonElement(json).jsonObject

    /** A relay that knows kind 3s and reactions. */
    private class FakeRelay(
        val follows: Map<String, Int>,
        val reactions: List<Pair<String, String>> = emptyList(),
    ) {
        val asked = mutableListOf<List<JsonObject>>()
        /** False: the kind 3 lookup times out (some relay never answered). */
        var answersAll = true
        /** The next kind 3 lookup throws. */
        var throwOnce = false

        fun answer(filters: List<JsonObject>, onEvent: (JsonObject) -> Unit): Boolean {
            asked += filters
            val followLookup = filters.any { it.containsKey("authors") }
            if (followLookup && throwOnce) {
                throwOnce = false
                throw IllegalStateException("relay sent something odd")
            }
            for (filter in filters) {
                val kinds = filter["kinds"]!!.jsonArray.map { it.jsonPrimitive.content }
                if ("3" in kinds) {
                    for (author in filter["authors"]!!.jsonArray.map { it.jsonPrimitive.content }) {
                        val n = follows[author] ?: continue
                        val p = (0 until n).joinToString(",") { """["p","f$it"]""" }
                        onEvent(Json.parseToJsonElement("""{"kind":3,"pubkey":"$author","created_at":1,"tags":[$p]}""").jsonObject)
                    }
                } else {
                    val ids = filter["#e"]!!.jsonArray.map { it.jsonPrimitive.content }.toSet()
                    for ((who, id) in reactions) if (id in ids) {
                        onEvent(Json.parseToJsonElement("""{"kind":7,"pubkey":"$who","tags":[["e","$id"]]}""").jsonObject)
                    }
                }
            }
            return !followLookup || answersAll
        }

        fun followLookups() = asked.count { f -> f.any { it.containsKey("authors") } }
    }

    private fun TestScope.screener(
        relay: FakeRelay,
        shown: MutableList<List<String>>,
        onPass: () -> Unit = {},
    ) = TopicFeedScreener(
        scope = this,
        query = { filters, onEvent -> relay.answer(filters, onEvent) },
        isValid = { true },
        onShown = { notes -> shown += notes.map { it.id } },
        onPass = onPass,
    )

    @Test fun aThrownLookupIsRetriedOnItsOwn() = runTest {
        val relay = FakeRelay(follows = mapOf("person" to 150)).apply { throwOnce = true }
        val shown = mutableListOf<List<String>>()
        var passes = 0
        val s = screener(relay, shown, onPass = { passes += 1 })
        s.add(note("a", "person", 1))
        advanceUntilIdle()
        // The failed lookup still ran a pass, and person was asked again on
        // the retry timer, with no other post needed.
        assertTrue(passes > 0)
        assertEquals(2, relay.followLookups())
        assertEquals(listOf("a"), shown.last())
        assertTrue(s.isSettled())
    }

    @Test fun aTimedOutLookupIsAskedAgainBeforeCountingZero() = runTest {
        // "quiet" has no follow list anywhere, but a relay never answers.
        val relay = FakeRelay(follows = mapOf("person" to 150)).apply { answersAll = false }
        val shown = mutableListOf<List<String>>()
        val s = screener(relay, shown)
        s.add(note("a", "person", 1))
        s.add(note("q1", "quiet", 2))
        advanceUntilIdle()
        // A found follow list counts even from a partial answer.
        assertEquals(listOf("a"), shown.last())
        // quiet: asked 3 times on the retry timer, then counted as 0.
        assertEquals(3, relay.followLookups())
        s.add(note("q2", "quiet", 3))
        advanceUntilIdle()
        assertEquals(3, relay.followLookups())
        // A newcomer is asked about; quiet isn't asked again.
        relay.answersAll = true
        s.add(note("n", "newcomer", 4))
        advanceUntilIdle()
        assertEquals(4, relay.followLookups())
        assertEquals(listOf("newcomer"), relay.asked.last().flatMap { f -> f["authors"]!!.jsonArray.map { it.jsonPrimitive.content } })
    }

    @Test fun aCompleteAnswerWithNoFollowListCountsZeroAtOnce() = runTest {
        val relay = FakeRelay(follows = emptyMap())
        val s = screener(relay, mutableListOf())
        s.add(note("q1", "quiet", 1))
        advanceUntilIdle()
        s.add(note("q2", "quiet", 2))
        advanceUntilIdle()
        assertEquals(1, relay.followLookups())
    }

    @Test fun settlesOnceEveryAuthorHasBeenAskedAbout() = runTest {
        val relay = FakeRelay(follows = mapOf("bot" to 0))
        var passes = 0
        val s = screener(relay, mutableListOf(), onPass = { passes += 1 })
        assertTrue("nothing on hand is settled", s.isSettled())
        s.add(note("b", "bot", 1))
        assertFalse(s.isSettled())
        advanceUntilIdle()
        // Nothing shown, but the pass ran and every author was asked about.
        assertTrue(s.isSettled())
        assertTrue(passes > 0)
    }

    @Test fun botsWaitForTheirCountThenDropOut() = runTest {
        val relay = FakeRelay(follows = mapOf("person" to 150, "bot" to 10))
        val shown = mutableListOf<List<String>>()
        val s = screener(relay, shown)
        s.add(note("b", "bot", 2))
        s.add(note("a", "person", 1))
        s.add(note("c", "nobody", 3)) // no kind 3 anywhere: counts as 0
        advanceUntilIdle()
        assertEquals(listOf("a"), shown.last())
        // One batched kind 3 lookup for the three authors.
        assertEquals(1, relay.asked.count { f -> f.any { it.containsKey("authors") } })
    }

    @Test fun postsTwoPeopleRespondedToGoFirst() = runTest {
        val relay = FakeRelay(
            follows = mapOf("p" to 50, "q" to 50, "r" to 50),
            // The author's own reaction doesn't count; one person once doesn't either.
            reactions = listOf("x" to "old", "y" to "old", "r" to "mid", "x" to "mid"),
        )
        val shown = mutableListOf<List<String>>()
        val s = screener(relay, shown)
        s.add(note("new", "p", 3))
        s.add(note("mid", "r", 2))
        s.add(note("old", "q", 1))
        advanceUntilIdle()
        assertEquals(listOf("old", "new", "mid"), shown.last())
    }

    @Test fun resetDropsThePoolButKeepsWhatItLearnedAboutAuthors() = runTest {
        val relay = FakeRelay(follows = mapOf("p" to 50))
        val shown = mutableListOf<List<String>>()
        val s = screener(relay, shown)
        s.add(note("a", "p", 1))
        advanceUntilIdle()
        val asked = relay.asked.size
        s.reset()
        s.add(note("b", "p", 2))
        advanceUntilIdle()
        assertEquals(listOf("b"), shown.last())
        // p's follow count was not asked for again.
        assertEquals(0, relay.asked.drop(asked).count { f -> f.any { it.containsKey("authors") } })
    }

    @Test fun oldestIsFromThePool() = runTest {
        val s = screener(FakeRelay(follows = emptyMap()), mutableListOf())
        s.add(note("new", "bot", 5))
        s.add(note("old", "bot", 1))
        advanceUntilIdle()
        assertEquals("old", s.oldest()?.id)
    }
}
