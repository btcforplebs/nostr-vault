package com.nostrvault.data.model

import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.put
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/** Mirrors HavenApp/MediaLogicTests/Tests/MediaLogicTests/GlobeLiveTests.swift. */
class GlobeLiveTest {
    private val me = "0".repeat(64)
    private val a = "a".repeat(64)
    private val b = "b".repeat(64)
    private val d = "d".repeat(64)
    private val now = 1_800_000_000.0

    private fun event(kind: Int, tags: List<List<String>>, id: String = "c".repeat(64), createdAt: Double = now - 5): JsonObject =
        buildJsonObject {
            put("id", id)
            put("pubkey", a)
            put("kind", kind)
            put("created_at", createdAt)
            put("tags", JsonArray(tags.map { tag -> JsonArray(tag.map { JsonPrimitive(it) }) }))
        }

    private fun arrival(event: JsonObject) = GlobeArcs.arrival(event, nowSeconds = now)

    @Test fun liveArrivalsStartOnButStayOffForWhoeverTurnedThemOff() {
        // A new install, or someone who never touched the antenna.
        assertTrue(LiveArcsSetting.DEFAULT_ON)
        // Skipped: the stored on/off round trip — UserDefaults storage (SharedPreferences here) is not tested.
        // Its own key, apart from the feeds' and sorts' switches (the spinning key is skipped: not ported).
        val keys = listOf(LiveArcsSetting.KEY) + GlobeArcs.Ring.entries.map(LiveArcsSetting::key) +
            GlobeArcs.Sort.entries.map(LiveArcsSetting::key)
        assertEquals(keys.size, keys.toSet().size)
    }

    @Test fun eachArrivalKnowsWhatItIs() {
        assertEquals(GlobeArcs.Sort.NOTE, arrival(event(1, listOf(listOf("p", b))))?.sort)
        assertEquals(GlobeArcs.Sort.REPLY, arrival(event(1, listOf(listOf("e", d, "", "reply", b))))?.sort)
        assertEquals(GlobeArcs.Sort.REPOST, arrival(event(6, listOf(listOf("e", d), listOf("p", b))))?.sort)
        // A quote is a new note.
        assertEquals(GlobeArcs.Sort.NOTE, arrival(event(1, listOf(listOf("e", d, "", "mention"), listOf("p", b))))?.sort)
        // Answering yourself in a thread is still a reply.
        assertEquals(GlobeArcs.Sort.REPLY, arrival(event(1, listOf(listOf("e", d, "", "reply", a), listOf("p", b))))?.sort)
    }

    @Test fun aReactionFliesFromTheReactorToWhoeverTheyReactedTo() {
        // NIP-25: the last p tag is the person reacted to.
        val reaction = arrival(event(7, listOf(listOf("e", d), listOf("p", me), listOf("p", b))))
        assertEquals(GlobeArcs.Sort.REACTION, reaction?.sort)
        assertEquals(a, reaction?.author)
        assertEquals(listOf(b), reaction?.targets)
        assertNotEquals(GlobeArcs.Sort.ZAP, reaction?.sort)
        // One we can't place doesn't fly, so it never lands on you by default.
        assertNull(arrival(event(7, listOf(listOf("e", d)))))
        assertNull(arrival(event(7, listOf(listOf("p", b)))))
        assertNull(arrival(event(7, listOf(listOf("e", d), listOf("p", "npub-not-hex")))))
        // Nor does reacting to yourself.
        assertNull(arrival(event(7, listOf(listOf("e", d), listOf("p", a)))))
        // Too old is a relay catching up.
        assertNull(arrival(event(7, listOf(listOf("e", d), listOf("p", b)), createdAt = now - GlobeArcs.MAX_AGE - 1)))
        // Its line keeps what it is, so it draws as a smaller star.
        val board = GlobeArcs.Board()
        board.add(reaction!!)
        board.step(0.0, me)
        assertEquals(listOf(b), board.lines.map { it.to })
        assertEquals(GlobeArcs.Sort.REACTION, board.lines.first().sort)
    }

    @Test fun theSwitchesPickWhatFlies() {
        var show = GlobeLive.Show()
        assertTrue(GlobeArcs.Sort.entries.all(show::allows))
        show = show.copy(replies = false, zaps = false)
        assertEquals(
            listOf(GlobeArcs.Sort.NOTE, GlobeArcs.Sort.REPOST, GlobeArcs.Sort.REACTION),
            GlobeArcs.Sort.entries.filter(show::allows),
        )
        show = show.copy(reactions = false)
        assertFalse(show.allows(GlobeArcs.Sort.REACTION))
    }

    @Test fun aSortSwitchedOffIsNotAskedFor() {
        var show = GlobeLive.Show()
        assertEquals(listOf(1, 1111, 7), show.noteKinds)
        assertEquals(listOf(1, 1111, 7, 6, 16), show.wideKinds)
        show = show.copy(reactions = false, reposts = false)
        assertEquals(listOf(1, 1111), show.noteKinds)
        assertEquals(listOf(1, 1111), show.wideKinds)
        // Notes and replies share kind 1: either keeps it.
        show = show.copy(notes = false)
        assertEquals(listOf(1, 1111), show.noteKinds)
        show = show.copy(replies = false)
        assertEquals(emptyList<Int>(), show.noteKinds)
        show = show.copy(reposts = true)
        assertEquals(listOf(6, 16), show.wideKinds)
        // A different set of switches is a different REQ.
        assertNotEquals(GlobeLive.Show(), show)
    }

    @Test fun aBiggerZapStrikesHarder() {
        val strengths = listOf(0L, 21L, 1_000L, 21_000L, 100_000L, 10_000_000L).map(GlobeZaps::zapStrength)
        assertEquals(strengths.sorted(), strengths)
        assertEquals(0.15, strengths.first(), 0.0)
        assertEquals(1.0, strengths.last(), 0.0)
        assertEquals(1.0, GlobeZaps.zapStrength(100_000), 0.0)
        // A strong zap forks twice, a light one once.
        val seed = GlobeBolt.seed("zap")
        assertEquals(1, GlobeBolt.forks(seed, 0.2).size)
        assertEquals(2, GlobeBolt.forks(seed, 0.9).size)
        // The flicker stutters while it flashes and holds still after.
        val levels = (0 until 16).map { GlobeBolt.flicker(seed, it) }
        assertTrue(levels.all { it in 0.55..1.0 })
        assertTrue(levels.toSet().size > 8)
        assertEquals(1.0, GlobeBolt.flicker(seed, -1), 0.0)
        // The board carries the strength to the bolt.
        val board = GlobeArcs.Board()
        board.add(GlobeArcs.Arrival("e".repeat(64), a, listOf(b), sort = GlobeArcs.Sort.ZAP, strength = 0.8))
        board.step(0.0, me)
        assertEquals(0.8, board.lines.first().strength, 0.0)
    }

    // Skipped: theGlobeHoldsStillWithSpinningOff — the globe spinning setting is not ported.
}
