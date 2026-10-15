package com.nostrvault.data.model

import com.nostrvault.ui.components.GlobeRelayLink
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.int
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonPrimitive
import kotlinx.serialization.json.long
import kotlinx.serialization.json.put
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/** Mirrors HavenApp/MediaLogicTests/Tests/MediaLogicTests/GlobeStormTests.swift. */
class GlobeStormTest {
    private fun key(n: Int): String = String.format("%064x", n.toLong() * 0x1234567 + 1)
    private val me = "0".repeat(64)
    private val event = """{"id":"${key(1)}","pubkey":"${key(2)}","kind":1,"created_at":1,"tags":[],"content":"hi","sig":""}"""

    private fun isGlobe(message: String) = GlobeStorm.isGlobeMessage(message)

    // ── The feed skips the globe's messages on a shared connection ──

    @Test fun aGlobeMessageIsTheGlobesAndAFeedMessageOnTheSameSocketIsNot() {
        assertTrue(isGlobe("""["EVENT","arcs-1a2b3c4d",$event]"""))
        assertTrue(isGlobe("""["EVENT","arcs-1a2b3c4d-2",$event]"""))
        assertTrue(isGlobe("""[ "EVENT", "arcs-1a2b3c4d", $event]"""))
        assertTrue(isGlobe("""["EOSE","arcs-1a2b3c4d"]"""))
        assertTrue(isGlobe("""["CLOSED","arcs-1a2b3c4d","error: too many"]"""))
        for (sub in listOf("feed-wss://relay.example", "m-1", "rx-2", "zaps-3", "tfetch-4")) {
            assertFalse(sub, isGlobe("""["EVENT","$sub",$event]"""))
        }
        assertFalse(isGlobe("""["NOTICE","arcs- is not a sub id here"]"""))
        assertFalse(isGlobe("""["OK","${key(1)}",true,""]"""))
        assertFalse(isGlobe(""))
        // A note whose text mentions arcs- is not the globe's.
        assertFalse(isGlobe("""["EVENT","feed-x",{"content":"arcs-"}]"""))
    }

    @Test fun aGlobeMessageIsCaughtWhateverWhitespaceTheRelaySends() {
        for (gap in listOf("\t", "\n", "\r\n", " \t\r\n ", " ".repeat(64), "\n".repeat(50))) {
            val shown = gap.replace("\t", "\\t").replace("\r", "\\r").replace("\n", "\\n")
            assertTrue("EVENT $shown", isGlobe("[$gap\"EVENT\",$gap\"arcs-1a2b3c4d\",$gap$event]"))
            assertTrue("lead $shown", isGlobe("$gap[\"EVENT\"$gap,\"arcs-1a2b3c4d\",$event$gap]"))
            assertTrue("EOSE $shown", isGlobe("[\"EOSE\",$gap\"arcs-1a2b3c4d\"]"))
            assertTrue("CLOSED $shown", isGlobe("[\"CLOSED\",$gap\"arcs-1a2b3c4d\",\"\"]"))
            for (sub in listOf("feed-wss://relay.example", "m-1", "rx-2")) {
                assertFalse("$sub $shown", isGlobe("[$gap\"EVENT\",$gap\"$sub\",$gap$event]"))
            }
            assertFalse("NOTICE $shown", isGlobe("[\"NOTICE\",$gap\"arcs-1a2b3c4d\"]"))
            assertFalse("content $shown", isGlobe("[\"EVENT\",$gap\"feed-x\",{\"content\":\"arcs-1\"}]"))
        }
        // A sub id the relay escapes is still read as itself.
        assertTrue(isGlobe("""["EVENT","arcs\u002d1a2b3c4d",$event]"""))
        // Not JSON, or not an array: not the globe's.
        assertFalse(isGlobe("""["EVENT","arcs-1"""))
        assertFalse(isGlobe("""{"EVENT":"arcs-1"}"""))
    }

    private fun filter(authors: List<String>) = buildJsonObject {
        put("kinds", JsonArray(listOf(JsonPrimitive(1))))
        put("authors", JsonArray(authors.map { JsonPrimitive(it) }))
    }

    private val kinds1 = buildJsonObject { put("kinds", JsonArray(listOf(JsonPrimitive(1)))) }

    @Test fun everyGlobeRequestIsUnderTheGlobePrefix() {
        val filters = (0 until 4).map { n -> filter((0 until 500).map { key(it + n * 500) }) }
        val requests = GlobeArcs.requests(filters, GlobeStorm.SUBSCRIPTION_PREFIX + "abcd1234")
        assertTrue(requests.size > 1)
        for (request in requests) {
            val array = Json.parseToJsonElement(request).jsonArray
            assertTrue(array[1].jsonPrimitive.content.startsWith(GlobeStorm.SUBSCRIPTION_PREFIX))
        }
        // Every reply to them is the globe's.
        assertEquals(requests.size, GlobeStorm.closes(requests).size)
    }

    @Test fun closingOnlyEverClosesTheGlobesSubscriptions() {
        val mine = GlobeArcs.requests(listOf(kinds1), "arcs-abcd1234")
        val feeds = GlobeArcs.requests(listOf(kinds1), "feed-wss://relay.example")
        assertEquals(listOf("""["CLOSE","arcs-abcd1234"]"""), GlobeStorm.closes(mine + feeds))
    }

    // ── What the globe asks each relay for ──

    private fun kindsOf(f: JsonObject) = (f["kinds"] as JsonArray).map { it.jsonPrimitive.int }

    @Test fun discoverAndGlobalAreOneAuthorlessFilterSoTheWholeWebFits() {
        val follows = (0 until 1_200).map(::key)
        val ringSets = listOf(
            setOf(GlobeArcs.Ring.DISCOVER),
            setOf(GlobeArcs.Ring.GLOBAL),
            setOf(GlobeArcs.Ring.FOLLOWING, GlobeArcs.Ring.DISCOVER, GlobeArcs.Ring.GLOBAL),
        )
        for (rings in ringSets) {
            val filters = GlobeStorm.storm(rings, GlobeLive.Show(), follows, since = 100)
            assertEquals(1, filters.size)
            assertNull(filters[0]["authors"])
            assertEquals(setOf(1, 1111, 7, 6, 16, GlobeArcs.ZAP_KIND), kindsOf(filters[0]).toSet())
            assertEquals(100L, filters[0]["since"]!!.jsonPrimitive.long)
        }
    }

    @Test fun followingAloneKeepsToItsAuthors() {
        val follows = (0 until 1_200).map(::key)
        val filters = GlobeStorm.storm(setOf(GlobeArcs.Ring.FOLLOWING), GlobeLive.Show(), follows, since = 100)
        val byAuthor = filters.filter { it["authors"] != null }
        assertEquals(listOf(500, 500, 200), byAuthor.map { (it["authors"] as JsonArray).size })
        // Zap receipts carry the LNURL server's key: one filter of their own.
        assertEquals(listOf(listOf(GlobeArcs.ZAP_KIND)), filters.filter { it["authors"] == null }.map(::kindsOf))
    }

    @Test fun aSwitchedOffSortIsNeverAskedFor() {
        val show = GlobeLive.Show(reactions = false, reposts = false, zaps = false)
        val kinds = GlobeStorm.storm(setOf(GlobeArcs.Ring.GLOBAL), show, emptyList(), 0).firstOrNull()?.let(::kindsOf)
        assertEquals(listOf(1, 1111), kinds)
        val none = GlobeLive.Show(notes = false, replies = false, reposts = false, reactions = false, zaps = false)
        assertTrue(GlobeStorm.storm(setOf(GlobeArcs.Ring.GLOBAL), none, emptyList(), 0).isEmpty())
        assertTrue(GlobeStorm.storm(emptySet(), GlobeLive.Show(), emptyList(), 0).isEmpty())
    }

    // ── Drawing a storm cheaply ──

    @Test fun opacitiesFallIntoAFewBands() {
        assertEquals(0, GlobeStorm.band(0.0))
        assertEquals(0, GlobeStorm.band(0.005))
        assertEquals(1, GlobeStorm.band(0.02))
        assertEquals(GlobeStorm.ALPHA_BANDS, GlobeStorm.band(1.0))
        assertEquals(GlobeStorm.ALPHA_BANDS, GlobeStorm.band(3.0))
        val bands = (0..1000).map { GlobeStorm.band(it * 0.001) }.toSet()
        assertEquals(GlobeStorm.ALPHA_BANDS + 1, bands.size)
        for (i in 5..100) {
            val a = i * 0.01
            assertEquals(a, GlobeStorm.bandAlpha(GlobeStorm.band(a)), 0.5 / GlobeStorm.ALPHA_BANDS + 1e-9)
        }
        assertTrue(GlobeStorm.arcSamples(300) < GlobeStorm.arcSamples(10))
    }

    @Test fun onlyTheNewestLinesGetFaces() {
        val board = GlobeArcs.Board()
        for (n in 0 until 100) board.add(GlobeArcs.Arrival(key(5000 + n), key(n + 1), listOf(key(n + 200))))
        board.step(0.0, me)
        val faces = board.faceKeys(GlobeStorm.MAX_ARC_FACES, me)
        assertEquals(GlobeStorm.MAX_ARC_FACES, faces.size)
        assertEquals(key(100), faces.first())
        assertFalse(key(1) in faces)
        // The core never gets a second face.
        val toMe = GlobeArcs.Board()
        toMe.add(GlobeArcs.Arrival(key(9000), key(1), emptyList()))
        toMe.step(0.0, me)
        assertEquals(listOf(key(1)), toMe.faceKeys(5, me))
    }

    @Test fun aQuietGlobeDrawsSlowAndABusyOneAtFullRate() {
        val board = GlobeArcs.Board()
        for (n in 0 until GlobeStorm.BUSY_LINES - 1) board.add(GlobeArcs.Arrival(key(n), key(n + 1), listOf(me)))
        board.step(0.0, me)
        assertFalse(board.isBusy)
        board.add(GlobeArcs.Arrival(key(999), key(2), listOf(me)))
        assertTrue(board.isBusy)
    }

    @Test fun theSeenListForgetsOnlyPastItsCap() {
        val board = GlobeArcs.Board()
        val cap = GlobeArcs.Board.SEEN_CAP
        for (n in 0 until cap + 10) board.add(GlobeArcs.Arrival(key(n), key(1), listOf(me)))
        board.step(0.0, me)
        // A recent one sent again by another relay is still a repeat.
        // (Kotlin's `waiting` is private: read it from what the next step lets on.)
        board.add(GlobeArcs.Arrival(key(cap), key(1), listOf(me)))
        assertTrue(board.step(0.0, me).isEmpty())
        // The very first was forgotten to make room.
        board.add(GlobeArcs.Arrival(key(0), key(1), listOf(me)))
        assertEquals(1, board.step(0.0, me).size)
    }

    // Skipped: theRateCountsEachNoteOnceOverTheLastMinute — RateMeter is not ported.
    // Skipped: frameStatsReportAverageAndP95 — FrameStats is not ported.

    // ── Extra ──

    @Test fun isGlobeMessageCatchesAnEscapedSubId() {
        assertTrue(isGlobe("""["EVENT","arcs\u002dxyz",$event]"""))
    }

    @Test fun isGlobeMessageIsFalseForANoticeNonJsonAndAFeedSubId() {
        assertFalse(isGlobe("""["NOTICE","arcs-xyz"]"""))
        assertFalse(isGlobe("not json at all arcs-xyz"))
        assertFalse(isGlobe("""["EVENT","feed-wss://relay.example",$event]"""))
    }

    @Test fun isGlobeSubscriptionTakesOnlyRelayAnswers() {
        assertTrue(GlobeStorm.isGlobeSubscription("EVENT", "arcs-1"))
        assertFalse(GlobeStorm.isGlobeSubscription("NOTICE", "arcs-1"))
    }

    @Test fun eventOfReturnsTheEventOnlyForAGlobeEvent() {
        val ids = setOf("arcs-1a2b3c4d")
        val globe = GlobeRelayLink.eventOf("""["EVENT","arcs-1a2b3c4d",$event]""", ids)
        assertNotNull(globe)
        assertEquals(key(1), globe!!["id"]!!.jsonPrimitive.content)
        assertNull(GlobeRelayLink.eventOf("""["EVENT","feed-wss://relay.example",$event]""", ids))
        assertNull(GlobeRelayLink.eventOf("""["EOSE","arcs-1a2b3c4d"]""", ids))
    }

    /** Two globe links on one socket (the wide REQ and notes to you): each reads only its own answers (Tron, PR 738). */
    @Test fun eventOfIgnoresAnotherGlobeLinksSubscription() {
        val mine = setOf("arcs-aaaaaaaa", "arcs-aaaaaaaa-1")
        assertNull(GlobeRelayLink.eventOf("""["EVENT","arcs-bbbbbbbb",$event]""", mine))
        assertNotNull(GlobeRelayLink.eventOf("""["EVENT","arcs-aaaaaaaa-1",$event]""", mine))
    }
}
