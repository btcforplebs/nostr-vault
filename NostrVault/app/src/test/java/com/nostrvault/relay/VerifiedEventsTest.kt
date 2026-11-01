package com.nostrvault.relay

import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.jsonObject
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test

/** Each event's signature is checked once; anything that differs, or fails, is checked again. */
class VerifiedEventsTest {
    private val id = "a".repeat(64)
    private val pubkey = "b".repeat(64)
    private val goodSig = "c".repeat(128)

    private fun event(content: String = "hello", sig: String = goodSig, reordered: Boolean = false): JsonObject {
        val text = if (reordered) {
            """{"sig":"$sig","content":"$content","tags":[["t","nostr"]],"kind":1,"created_at":1700000000,"pubkey":"$pubkey","id":"$id"}"""
        } else {
            """{"id":"$id","pubkey":"$pubkey","created_at":1700000000,"kind":1,"tags":[["t","nostr"]],"content":"$content","sig":"$sig"}"""
        }
        return Json.parseToJsonElement(text).jsonObject
    }

    /** Stands in for the Schnorr check: only the real note, as signed, passes. */
    private var calls = 0
    private val check: (String) -> Boolean = { json ->
        calls++
        val e = Json.parseToJsonElement(json).jsonObject
        e["sig"].toString() == "\"$goodSig\"" && e["content"].toString() == "\"hello\""
    }

    @Before fun setUp() = VerifiedEvents.clearForTest()
    @After fun tearDown() = VerifiedEvents.clearForTest()

    @Test
    fun `a good note is checked once however many relays send it`() {
        repeat(5) { assertTrue(VerifiedEvents.verify(event(), check)) }
        // Another relay's copy, fields in another order: the same note.
        assertTrue(VerifiedEvents.verify(event(reordered = true), check))
        assertEquals(1, calls)
    }

    @Test
    fun `a bad signature from an outside relay is refused every time`() {
        repeat(3) { assertFalse(VerifiedEvents.verify(event(sig = "d".repeat(128)), check)) }
        assertEquals(3, calls)
    }

    @Test
    fun `a forged copy reusing a checked note's id and signature is checked and refused`() {
        assertTrue(VerifiedEvents.verify(event(), check))
        assertFalse(VerifiedEvents.verify(event(content = "send me sats"), check))
        assertEquals(2, calls)
    }

    @Test
    fun `an event missing a signed field never passes`() {
        val noSig = JsonObject(event().filterKeys { it != "sig" })
        assertFalse(VerifiedEvents.verify(noSig) { true })
        assertEquals(null, VerifiedEvents.key(noSig))
    }

    @Test
    fun `json text is checked once too`() {
        val text = event().toString()
        assertTrue(VerifiedEvents.verify(text, check))
        assertTrue(VerifiedEvents.verify(text, check))
        assertFalse(VerifiedEvents.verify("not json", check))
        assertEquals(1, calls)
    }
}
