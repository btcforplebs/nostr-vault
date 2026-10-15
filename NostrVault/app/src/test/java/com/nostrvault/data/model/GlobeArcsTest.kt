package com.nostrvault.data.model

import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonPrimitive
import kotlinx.serialization.json.put
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/** Mirrors HavenApp/MediaLogicTests/Tests/MediaLogicTests/GlobeArcsTests.swift. */
class GlobeArcsTest {
    private val me = "0".repeat(64)
    private fun key(n: Int): String = String.format("%064x", n.toLong() * 0x1234567 + 1)
    private val now = 1_800_000_000.0
    private val life = GlobeArcs.TRAVEL + GlobeArcs.HOLD + GlobeArcs.FADE

    private fun tagsJson(tags: List<List<String>>) = JsonArray(tags.map { tag -> JsonArray(tag.map { JsonPrimitive(it) }) })

    private fun event(n: Int, author: String, kind: Int, tags: List<List<String>>, age: Double = 5.0): JsonObject =
        buildJsonObject {
            put("id", key(1000 + n))
            put("pubkey", author)
            put("kind", kind)
            put("created_at", now - age)
            put("tags", tagsJson(tags))
        }

    private fun note(n: Int, by: String, to: List<String> = emptyList(), kind: Int = 1, age: Double = 5.0): JsonObject =
        event(n, by, kind, to.map { listOf("p", it) } + listOf(listOf("e", key(7), "", "mention")), age)

    private fun arrival(event: JsonObject) = GlobeArcs.arrival(event, nowSeconds = now)

    @Test fun aNoteToYouIsOneLineToYou() {
        assertEquals(listOf(me), arrival(note(1, key(1), listOf(me)))?.targets)
    }

    @Test fun aNoteNamingSeveralPeopleIsOneLineEachOnceWithoutTheAuthor() {
        val a = arrival(note(1, key(1), listOf(key(2), key(3), key(2), key(1))))
        assertEquals(listOf(key(2), key(3)), a?.targets)
    }

    @Test fun aNoteNamingACrowdIsCapped() {
        val a = arrival(note(1, key(1), (2..20).map(::key)))
        assertEquals(GlobeArcs.MAX_TARGETS, a?.targets?.size)
    }

    @Test fun aReplyFliesToThePersonItAnswersNotTheWholeThread() {
        // root by 2, replied to by 3; 1 answers 3.
        val tags = listOf(
            listOf("e", key(50), "", "root", key(2)), listOf("e", key(51), "", "reply", key(3)),
            listOf("p", key(2)), listOf("p", key(3)), listOf("p", key(4)),
        )
        assertEquals(listOf(key(3)), arrival(event(1, key(1), 1, tags))?.targets)
        // A direct reply to the root names only the root.
        val direct = listOf(listOf("e", key(50), "", "root", key(2)), listOf("p", key(2)), listOf("p", key(4)))
        assertEquals(listOf(key(2)), arrival(event(2, key(1), 1, direct))?.targets)
        // Older clients leave the pubkey slot empty: the first p.
        val positional = listOf(listOf("e", key(50)), listOf("e", key(51)), listOf("p", key(3)), listOf("p", key(2)))
        assertEquals(listOf(key(3)), arrival(event(3, key(1), 1, positional))?.targets)
    }

    @Test fun aReplyWeCantPlaceDoesntFlyIntoYou() {
        val marked = listOf(listOf("e", key(50), "", "root"), listOf("e", key(51), "", "reply"))
        assertNull(arrival(event(10, key(1), 1, marked)))
        val positional = listOf(listOf("e", key(50)), listOf("e", key(51)))
        assertNull(arrival(event(11, key(1), 1, positional)))
        val comment = listOf(listOf("E", key(50)), listOf("K", "1"), listOf("e", key(51)), listOf("k", "1"))
        assertNull(arrival(event(12, key(1), 1111, comment)))
        // A plain note aimed at no one still lands on you.
        val plain = arrival(event(13, key(1), 1, emptyList()))
        assertEquals(emptyList<String>(), plain?.targets)
        val board = GlobeArcs.Board()
        board.add(plain!!)
        board.step(0.0, me)
        assertEquals(listOf(me), board.lines.map { it.to })
    }

    @Test fun aPositionalReplyWithSeveralETagsFliesToTheFirstP() {
        val tags = listOf(
            listOf("e", key(50)), listOf("e", key(52)), listOf("e", key(51)),
            listOf("p", key(3)), listOf("p", key(2)), listOf("p", key(4)),
        )
        assertEquals(listOf(key(3)), arrival(event(14, key(1), 1, tags))?.targets)
        assertTrue(GlobeArcs.isReply(1, tags))
        // A quote's mention e isn't a parent: not a reply.
        assertFalse(GlobeArcs.isReply(1, listOf(listOf("e", key(50), "", "mention"), listOf("p", key(2)))))
    }

    @Test fun aNIP22CommentReplyFliesToo() {
        assertTrue(NIP10Thread.COMMENT_KIND in GlobeArcs.KINDS)
        val tags = listOf(
            listOf("E", key(50), "", key(2)), listOf("K", "1"), listOf("P", key(2)),
            listOf("e", key(51), "", key(3)), listOf("k", "1"), listOf("p", key(3)),
        )
        val a = arrival(event(4, key(1), 1111, tags))
        assertEquals(key(1), a?.author)
        assertEquals(listOf(key(3)), a?.targets)
        // Without the pubkey slot, the lowercase p is the parent's author.
        val bare = listOf(listOf("E", key(50)), listOf("K", "1"), listOf("e", key(51)), listOf("k", "1"), listOf("p", key(3)))
        assertEquals(listOf(key(3)), arrival(event(5, key(1), 1111, bare))?.targets)
        // A comment on a video isn't a note reply.
        val video = listOf(listOf("E", key(52)), listOf("K", "21"), listOf("e", key(52)), listOf("k", "21"), listOf("p", key(3)))
        assertNull(arrival(event(6, key(1), 1111, video)))
    }

    @Test fun aQuoteAndASelfReplyStillFlyToWhoTheyName() {
        val quote = listOf(listOf("e", key(50), "", "mention"), listOf("q", key(50)), listOf("p", key(2)))
        assertEquals(listOf(key(2)), arrival(event(7, key(1), 1, quote))?.targets)
        // Answering yourself in a thread: the others in it, not you.
        val selfReply = listOf(listOf("e", key(50), "", "reply", key(1)), listOf("p", key(1)), listOf("p", key(2)))
        assertEquals(listOf(key(2)), arrival(event(8, key(1), 1, selfReply))?.targets)
    }

    @Test fun onlyFreshNotesArrive() {
        assertNull(arrival(note(1, key(1), kind = 7)))
        assertNull(arrival(note(1, key(1), age = GlobeArcs.MAX_AGE + 1)))
        assertNull(arrival(note(1, "nope")))
        assertNotNull(arrival(note(1, key(1))))
    }

    @Test fun theSameNoteFromTwoRelaysDrawsOnce() {
        val board = GlobeArcs.Board()
        val a = arrival(note(1, key(1), listOf(me)))!!
        board.add(a)
        board.add(a)
        board.step(0.0, me)
        board.add(a)
        board.step(1.0, me)
        assertEquals(1, board.lines.size)
    }

    @Test fun aStarLetOnSurvivesARedrawAtTheSameInstant() {
        val board = GlobeArcs.Board()
        board.add(arrival(note(1, key(1)))!!)
        board.step(100.0, me)
        board.step(100.0, me)
        assertEquals(1, board.lines.size)
        board.step(100.01, me)
        assertEquals(1, board.lines.size)
    }

    @Test fun aStarIsDroppedOnceItHasFadedOut() {
        val board = GlobeArcs.Board()
        board.add(arrival(note(1, key(1)))!!)
        board.step(100.0, me)
        val end = 100 + GlobeArcs.TRAVEL + GlobeArcs.HOLD + GlobeArcs.FADE
        board.step(end - 0.05, me)
        assertEquals(1, board.lines.size)
        board.step(end + 0.05, me)
        assertTrue(board.lines.isEmpty())
    }

    @Test fun aNoteToNoOneFliesIntoYou() {
        val board = GlobeArcs.Board()
        board.add(arrival(note(1, key(1)))!!)
        board.step(0.0, me)
        assertEquals(listOf(key(1)), board.lines.map { it.from })
        assertEquals(listOf(me), board.lines.map { it.to })
        assertTrue(board.lines.all { it.toMe })
    }

    @Test fun yourOwnNoteToNoOneDrawsNothing() {
        val board = GlobeArcs.Board()
        board.add(arrival(note(1, me))!!)
        board.step(0.0, me)
        assertTrue(board.lines.isEmpty())
    }

    @Test fun aReplyFliesBetweenItsPartiesNotIntoYou() {
        val board = GlobeArcs.Board()
        board.add(arrival(note(1, key(1), listOf(key(2))))!!)
        board.step(0.0, me)
        assertEquals(listOf(key(2)), board.lines.map { it.to })
        assertFalse(board.lines.any { it.toMe })
    }

    @Test fun aRepostFliesFromTheReposterToWhoTheyReposted() {
        val repost = arrival(note(1, key(1), listOf(key(2)), kind = 6))
        assertEquals(key(1), repost?.author)
        assertEquals(listOf(key(2)), repost?.targets)
        assertNotNull(arrival(note(2, key(1), listOf(key(2)), kind = 16)))
    }

    private fun filter(kinds: List<Int>, since: Long, authors: List<String>? = null) = buildJsonObject {
        put("kinds", JsonArray(kinds.map { JsonPrimitive(it) }))
        put("since", since)
        if (authors != null) put("authors", JsonArray(authors.map { JsonPrimitive(it) }))
    }

    private fun parse(text: String) = Json.parseToJsonElement(text).jsonArray

    private fun firstAuthor(f: JsonObject): String? = (f["authors"] as? JsonArray)?.firstOrNull()?.jsonPrimitive?.content

    @Test fun aBigRequestIsSplitUnderTheRelaysSizeCap() {
        val authors = (0 until 1_500).map(::key)
        val filters = (0 until authors.size step 500).map { filter(listOf(1, 6, 16), 1, authors.subList(it, it + 500)) } +
            filter(listOf(1, 6, 16), 1)
        val one = JsonArray(listOf(JsonPrimitive("REQ"), JsonPrimitive("arcs-x")) + filters).toString().toByteArray()
        assertTrue(one.size > 100_000)
        val requests = GlobeArcs.requests(filters, "arcs-x")
        assertTrue(requests.size > 1)
        val ids = ArrayList<String>()
        val sent = ArrayList<JsonObject>()
        for (text in requests) {
            assertTrue(text.toByteArray().size <= GlobeArcs.MAX_REQUEST_BYTES)
            val req = parse(text)
            assertEquals("REQ", req[0].jsonPrimitive.content)
            ids += req[1].jsonPrimitive.content
            sent += req.drop(2).map { it as JsonObject }
        }
        // Every filter goes, once, in order, each REQ under its own id.
        assertEquals(ids.size, ids.toSet().size)
        assertEquals(filters.map(::firstAuthor), sent.map(::firstAuthor))
        // A small REQ stays one message with the id it was given.
        val small = GlobeArcs.requests(listOf(filter(listOf(1), 1)), "arcs-y")
        assertEquals(1, small.size)
        assertTrue(small[0].startsWith("[\"REQ\",\"arcs-y\","))
        // A single filter past the cap still goes, on its own.
        assertEquals(filters.size, GlobeArcs.requests(filters, "z", maxBytes = 10).size)
    }

    @Test fun aRepostWithNoPTagFliesIntoYou() {
        for (kind in listOf(6, 16)) {
            val repost = arrival(note(3 + kind, key(1), kind = kind))
            assertEquals(key(1), repost?.author)
            assertEquals(emptyList<String>(), repost?.targets)
            val board = GlobeArcs.Board()
            board.add(repost!!)
            board.step(0.0, me)
            assertEquals(listOf(me), board.lines.map { it.to })
            assertTrue(board.lines.all { it.toMe })
        }
    }

    @Test fun eachFeedSetsOutFromItsOwnShellWidestLast() {
        val follows = setOf(key(1), me)
        val discover = setOf(key(2))
        assertEquals(GlobeArcs.Ring.FOLLOWING, GlobeArcs.ring(key(1), follows, discover))
        assertEquals(GlobeArcs.Ring.FOLLOWING, GlobeArcs.ring(me, follows, discover))
        assertEquals(GlobeArcs.Ring.DISCOVER, GlobeArcs.ring(key(2), follows, discover))
        assertEquals(GlobeArcs.Ring.GLOBAL, GlobeArcs.ring(key(3), follows, discover))
        val radii = GlobeArcs.Ring.entries.map { it.radius }
        assertEquals(radii.sorted(), radii)
        assertEquals(radii.size, radii.toSet().size)
        // The line keeps its note's feed.
        val board = GlobeArcs.Board()
        board.add(arrival(note(1, key(3)))!!.copy(ring = GlobeArcs.Ring.GLOBAL))
        board.step(0.0, me)
        assertEquals(listOf(GlobeArcs.Ring.GLOBAL), board.lines.map { it.ring })
    }

    @Test fun aBusyGlobalNeverPushesOutYourFollows() {
        val board = GlobeArcs.Board()
        val mine = arrival(note(0, key(1), listOf(me)))!!.copy(ring = GlobeArcs.Ring.FOLLOWING)
        board.add(mine)
        board.step(0.0, me)
        for (n in 1..(GlobeArcs.MAX_LINES + 40)) {
            val ring = if (n % 3 == 0) GlobeArcs.Ring.DISCOVER else GlobeArcs.Ring.GLOBAL
            board.add(arrival(note(n, key(n + 100)))!!.copy(ring = ring))
        }
        board.step(1.0, me)
        val standing = board.lines.filter { it.retired == null }
        assertEquals(GlobeArcs.MAX_LINES, standing.size)
        // Your follow's line stands, though it is the oldest on the globe.
        assertTrue(standing.any { it.note == mine.id })
        // Global gives way before Discover does.
        assertTrue(board.lines.filter { it.retired != null }.all { it.ring == GlobeArcs.Ring.GLOBAL })
        assertEquals((GlobeArcs.MAX_LINES + 40) / 3, standing.count { it.ring == GlobeArcs.Ring.DISCOVER })
    }

    @Test fun everyArrivalFliesAtOnce() {
        val board = GlobeArcs.Board()
        for (n in 0 until 50) board.add(arrival(note(n, key(n + 1), listOf(me)))!!)
        assertEquals(50, board.step(0.0, me).size)
        assertEquals(50, board.lines.size)
        // Kotlin's `waiting` is private: nothing left waiting means the next step lets nothing on.
        assertTrue(board.step(0.0, me).isEmpty())
        assertTrue(board.isBusy)
    }

    @Test fun aBurstBetweenFramesKeepsAtMostACapsWorth() {
        val board = GlobeArcs.Board()
        for (n in 0 until GlobeArcs.MAX_LINES + 30) board.add(arrival(note(n, key(n + 1), listOf(me)))!!)
        // Kotlin's `waiting` is private: read it from what the next step lets on.
        val waiting = board.step(0.0, me)
        assertEquals(GlobeArcs.MAX_LINES, waiting.size)
        assertEquals(key(1000 + GlobeArcs.MAX_LINES + 29), waiting.last().id)
    }

    @Test fun standingLinesNeverPassTheCap() {
        val board = GlobeArcs.Board()
        var t = 0.0
        for (n in 0 until 400) {
            board.add(arrival(note(n, key(n + 1), listOf(key(1000 + n), key(2000 + n))))!!)
            board.step(t, me)
            assertTrue(board.lines.count { it.retired == null } <= GlobeArcs.MAX_LINES)
            t += 0.01
        }
        // Retired lines fade out quickly, so what is drawn stays near the cap.
        board.step(t + GlobeArcs.RETIRE_FADE, me)
        assertTrue(board.lines.size <= GlobeArcs.MAX_LINES)
    }

    @Test fun aStarTravelsLandsAndItsTrailFadesFirst() {
        val line = GlobeArcs.Line(key(9), key(1), me, true, GlobeArcs.Ring.FOLLOWING, 0.0, GlobeArcs.Sort.NOTE)
        assertEquals(0.0, GlobeArcs.stage(line, 0.0).alpha, 0.0)
        val mid = GlobeArcs.stage(line, GlobeArcs.TRAVEL / 2)
        assertEquals(0.5, mid.head, 0.001)
        assertEquals(1.0, mid.trail, 0.0)
        // Skipped: GlobeArcs.hasLanded asserts — hasLanded is not ported to Kotlin.
        // Landed: the trail is gone soon after, the light where it landed stays.
        val held = GlobeArcs.stage(line, GlobeArcs.TRAVEL + GlobeArcs.TRAIL_FADE)
        assertEquals(1.0, held.head, 0.0)
        assertEquals(0.0, held.trail, 1e-9)
        assertEquals(1.0, held.alpha, 0.0)
        val fading = GlobeArcs.stage(line, GlobeArcs.TRAVEL + GlobeArcs.HOLD + GlobeArcs.FADE / 2)
        assertEquals(0.5, fading.alpha, 0.001)
        assertEquals(0.0, GlobeArcs.stage(line, life).alpha, 1e-9)
        // Reduce Motion: no flight, the same fades.
        val still = GlobeArcs.stage(line, 0.3, reduceMotion = true)
        assertEquals(1.0, still.head, 0.0)
        assertTrue(still.trail < 1)
    }

    @Test fun notesHeldNeverOutgrowTheCap() {
        val board = GlobeArcs.Board()
        for (n in 0 until 2_000) board.add(arrival(note(n, key(n + 1), listOf(me)))!!)
        // Kotlin's `waiting` is private: what the step lets on is what waited.
        assertEquals(GlobeArcs.MAX_LINES, board.step(0.0, me).size)
        // Let on and faded out, they all go.
        board.step(life, me)
        assertTrue(board.isIdle)
    }

    @Test fun fadedLinesAreDropped() {
        val board = GlobeArcs.Board()
        board.add(arrival(note(1, key(1), listOf(me)))!!)
        board.step(0.0, me)
        board.step(life + 0.01, me)
        assertTrue(board.isIdle)
    }

    private fun minus(a: Vec3, b: Vec3) = a + b * -1.0
    private fun distance(a: Vec3, b: Vec3) = minus(a, b).length

    @Test fun linesBendOffTheGlobeAndEndOnTheirPeople() {
        val a = Vec3(1.6, 0.0, 0.0)
        val b = Vec3(0.0, 1.6, 0.0)
        assertEquals(0.0, distance(GlobeArcs.point(a, b, 0.0), a), 1e-9)
        assertEquals(0.0, distance(GlobeArcs.point(a, b, 1.0), b), 1e-9)
        // Lifted above the straight cut through the middle.
        assertTrue(GlobeArcs.point(a, b, 0.5).length > ((a + b) / 2.0).length)
        // A line into the core, and one straight across it, still bend.
        val toCore = GlobeArcs.point(a, Vec3.ZERO, 0.5)
        assertTrue(distance(toCore, Vec3(0.8, 0.0, 0.0)) > 0.1)
        val across = GlobeArcs.point(a, a * -1.0, 0.5)
        assertTrue(across.length > 0.3)
    }

    @Test fun aLineIntoTheCoreBendsAcrossTheScreenNotTowardTheViewer() {
        val facing = Vec3(0.0, 0.0, 1.0)
        val mid = GlobeArcs.point(Vec3(1.6, 0.0, 0.0), Vec3.ZERO, 0.5, facing)
        // The bend is sideways on screen (y), with none of it toward the camera (z).
        assertTrue(kotlin.math.abs(mid.y) > 0.1)
        assertEquals(0.0, mid.z, 1e-9)
        // A line straight along the view still bends.
        val along = GlobeArcs.point(Vec3(0.0, 0.0, 1.6), Vec3.ZERO, 0.5, facing)
        assertTrue(kotlin.math.hypot(along.x, along.y) > 0.1)
    }

    // ── Extra: GlobeArcs.requests ──

    private fun bigFilters(count: Int, authorsEach: Int) =
        (0 until count).map { f -> filter(listOf(1), 1, (0 until authorsEach).map { key(f * authorsEach + it) }) }

    @Test fun requestsKeepTheBareSubIdForASingleGroup() {
        val requests = GlobeArcs.requests(bigFilters(3, 2), "arcs-solo")
        assertEquals(1, requests.size)
        assertEquals("arcs-solo", parse(requests[0])[1].jsonPrimitive.content)
    }

    @Test fun requestsSplitWithIndexSuffixes() {
        // Each 100-author filter is about 6.7 KB; a 10 KB cap fits one per message.
        val requests = GlobeArcs.requests(bigFilters(3, 100), "arcs-split", maxBytes = 10_000)
        assertEquals(listOf("arcs-split-0", "arcs-split-1", "arcs-split-2"), requests.map { parse(it)[1].jsonPrimitive.content })
    }

    @Test fun requestsStayUnderMaxBytesUnlessOneFilterIsOversized() {
        val filters = bigFilters(10, 30) + bigFilters(1, 400) + bigFilters(5, 10)
        val maxBytes = 8_000
        val requests = GlobeArcs.requests(filters, "arcs-cap", maxBytes = maxBytes)
        assertTrue(requests.size > 1)
        var oversized = 0
        for (text in requests) {
            val size = text.toByteArray().size
            if (size > maxBytes) {
                oversized++
                assertEquals("an over-cap message holds a single filter", 3, parse(text).size)
            }
        }
        assertEquals(1, oversized)
    }

    @Test fun requestsKeepFilterOrder() {
        val filters = bigFilters(12, 40)
        val requests = GlobeArcs.requests(filters, "arcs-order", maxBytes = 9_000)
        assertTrue(requests.size > 1)
        val sent = requests.flatMap { parse(it).drop(2).map { f -> f as JsonObject } }
        assertEquals(filters, sent)
    }
}
