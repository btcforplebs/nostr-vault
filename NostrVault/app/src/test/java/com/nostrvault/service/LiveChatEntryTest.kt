package com.nostrvault.service

import kotlinx.serialization.json.Json
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

/**
 * A chat line counts only if its event verifies, and a zap names its zapper
 * only if the embedded request verifies too (Tron, #1308): a line's author can
 * be muted and opened as a profile, and the relays are the stream publisher's pick.
 */
class LiveChatEntryTest {
    private val json = Json { ignoreUnknownKeys = true }
    private val alice = "a".repeat(64)
    private val provider = "b".repeat(64)
    private val id = "c".repeat(64)

    private fun chat(pubkey: String = alice, eventId: String = id) =
        """["EVENT","s",{"id":"$eventId","pubkey":"$pubkey","created_at":100,"kind":1311,"tags":[],"content":"hi","sig":"x"}]"""

    private fun zap(requestPubkey: String) = run {
        val request = """{"id":"${"d".repeat(64)}","pubkey":"$requestPubkey","kind":9734,"tags":[],"content":"nice stream","sig":"y"}"""
        val escaped = request.replace("\"", "\\\"")
        """["EVENT","s",{"id":"$id","pubkey":"$provider","created_at":100,"kind":9735,"tags":[["bolt11","lnbc210n1p4fake"],["description","$escaped"]],"content":"","sig":"z"}]"""
    }

    @Test fun aVerifiedLineIsKept() {
        val e = parseChatEntry(chat(), "s", json) { true }
        assertEquals(alice, e?.pubkey)
        assertEquals("hi", e?.content)
    }

    @Test fun aLineThatFailsVerificationIsDropped() {
        assertNull(parseChatEntry(chat(), "s", json) { false })
    }

    @Test fun aPubkeyThatIsNotHexIsDroppedBeforeAnythingElse() {
        var asked = false
        assertNull(parseChatEntry(chat(pubkey = "a/b"), "s", json) { asked = true; true })
        assertNull(parseChatEntry(chat(eventId = "short"), "s", json) { true })
        assertEquals(false, asked)
    }

    @Test fun aZapNamesItsZapperOnlyWhenTheRequestVerifies() {
        val good = parseChatEntry(zap(alice), "s", json) { true }
        assertEquals(alice, good?.pubkey)
        assertEquals("nice stream", good?.content)
        assertEquals(21L, good?.zapSats)

        // The receipt verifies, the request inside it does not: the provider's key, no text.
        val forged = parseChatEntry(zap(alice), "s", json) { event -> "\"kind\":9735" in event }
        assertEquals(provider, forged?.pubkey)
        assertEquals("", forged?.content)

        val notHex = parseChatEntry(zap("x/y"), "s", json) { true }
        assertEquals(provider, notHex?.pubkey)
    }

    @Test fun anotherSubscriptionIsIgnored() {
        assertNull(parseChatEntry(chat(), "other", json) { true })
    }

    @Test
    fun `history jumps to the bottom, one new line glides`() {
        // Opening: the first batch, and later batches of history, jump.
        assertEquals(false, LiveChatService.animatesScroll(0, 1))
        assertEquals(false, LiveChatService.animatesScroll(0, 120))
        assertEquals(false, LiveChatService.animatesScroll(40, 75))
        // Live: one new message glides.
        assertEquals(true, LiveChatService.animatesScroll(75, 76))
        // A mute that drops lines does not glide either.
        assertEquals(false, LiveChatService.animatesScroll(76, 70))
    }
}
