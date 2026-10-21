package com.nostrvault.data.model

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * [QuoteRef] is the one definition of what a note quotes. These pin the two
 * properties that were broken when there were several: that a key the parser
 * produces is a key the fetcher accepts, and that an naddr survives the trip.
 */
class QuoteRefTest {

    private val eventHex = "a".repeat(64)
    private val otherHex = "b".repeat(64)
    private val authorHex = "c".repeat(64)

    /** Decodes by prefix alone, so the tests need no bech32 and no native library. */
    private val decoder = object : QuoteRef.Decoder {
        override fun noteToHex(note1: String) =
            if (note1 == "note1aaa") eventHex else null

        override fun neventToHex(nevent1: String) =
            if (nevent1 == "nevent1bbb") otherHex else null

        override fun naddrToCoordinate(naddr1: String) =
            if (naddr1 == "naddr1ccc") QuoteRef.Coordinate(30023, authorHex, "my-post") else null
    }

    // ── The regression: parser output must be fetcher input ──────────

    @Test
    fun `every key the parser produces is a key the fetcher can read`() {
        val content = "look nostr:note1aaa and nostr:nevent1bbb and nostr:naddr1ccc"

        val keys = QuoteRef.resolvedIdentifiers(content, decoder)

        assertEquals(3, keys.size)
        // The bug: FeedService decoded these as bech32, so every one came back
        // null and no quoted note ever resolved. Each must now name something.
        for (key in keys) {
            assertTrue("no key for $key", QuoteRef.key(key) != null)
        }
    }

    @Test
    fun `a hex event id reads as an event, not as nothing`() {
        assertEquals(QuoteRef.Key.Event(eventHex), QuoteRef.key(eventHex))
    }

    @Test
    fun `a coordinate reads as an address`() {
        val coordinate = QuoteRef.Coordinate(30023, authorHex, "my-post")
        val key = QuoteRef.key(QuoteRef.format(coordinate))
        assertEquals(QuoteRef.Key.Address(coordinate), key)
    }

    @Test
    fun `a key that is neither is rejected`() {
        assertNull(QuoteRef.key("nostr:note1aaa"))
        assertNull(QuoteRef.key(""))
        assertNull(QuoteRef.key("zz" + "a".repeat(62)))
    }

    // ── naddr ────────────────────────────────────────────────────────

    @Test
    fun `an naddr resolves to its coordinate`() {
        assertEquals(
            listOf("naddr:30023:$authorHex:my-post"),
            QuoteRef.resolvedIdentifiers("read nostr:naddr1ccc", decoder),
        )
    }

    @Test
    fun `a coordinate survives a round trip`() {
        val coordinate = QuoteRef.Coordinate(30023, authorHex, "my-post")
        assertEquals(coordinate, QuoteRef.parse(QuoteRef.format(coordinate)))
    }

    @Test
    fun `a d tag containing a colon survives`() {
        val coordinate = QuoteRef.Coordinate(30023, authorHex, "2026:09:08-notes")
        assertEquals(coordinate, QuoteRef.parse(QuoteRef.format(coordinate)))
    }

    @Test
    fun `an empty d tag is a real identifier, not a missing one`() {
        val coordinate = QuoteRef.Coordinate(30023, authorHex, "")
        assertEquals(coordinate, QuoteRef.parse(QuoteRef.format(coordinate)))
    }

    @Test
    fun `parse rejects a plain event id`() {
        assertNull(QuoteRef.parse(eventHex))
    }

    @Test
    fun `parse rejects a coordinate with no author`() {
        assertNull(QuoteRef.parse("naddr:30023::my-post"))
    }

    @Test
    fun `parse rejects a coordinate with a non-numeric kind`() {
        assertNull(QuoteRef.parse("naddr:article:$authorHex:my-post"))
    }

    // ── Extraction ───────────────────────────────────────────────────

    @Test
    fun `identifiers keep their order and drop repeats`() {
        val content = "nostr:nevent1bbb then nostr:note1aaa then nostr:nevent1bbb again"
        assertEquals(listOf("nevent1bbb", "note1aaa"), QuoteRef.identifiers(content))
    }

    @Test
    fun `a reference that will not decode is dropped, not passed through`() {
        // Passing the bech32 through is the original bug: it asked the relay
        // for an id that cannot exist.
        assertEquals(emptyList<String>(), QuoteRef.resolvedIdentifiers("nostr:note1zzz", decoder))
    }

    @Test
    fun `profile mentions are not quote references`() {
        assertEquals(emptyList<String>(), QuoteRef.identifiers("hi nostr:npub1aaa and nostr:nprofile1bbb"))
    }

    @Test
    fun `two references to the same event yield one key`() {
        val content = "nostr:note1aaa and again nostr:note1aaa"
        assertEquals(listOf(eventHex), QuoteRef.resolvedIdentifiers(content, decoder))
    }

    // ── nevent pointer: the author the miss lookup asks ──

    private fun hex(h: String) = ByteArray(h.length / 2) { h.substring(it * 2, it * 2 + 2).toInt(16).toByte() }
    private fun tlv(type: Int, value: ByteArray) = byteArrayOf(type.toByte(), value.size.toByte()) + value

    /** Plural's quote in Logen's thread: author first, then the id, no relay. */
    @Test
    fun `nevent pointer keeps the author of a real quote`() {
        val author = "f42a02152031590dcc3a0a67db51316b7365e4aef34abbec9619c12e88f006b5"
        val id = "a2f86e95d19056411861904c95a5bd19543f1769b354866567c4c014cef59e64"
        assertEquals(
            QuoteRef.EventPointer(id, author),
            QuoteRef.eventPointerFromNeventTlv(tlv(2, hex(author)) + tlv(0, hex(id))),
        )
    }

    /** The sender must not choose the host the app dials: the relay hint is dropped. */
    @Test
    fun `nevent pointer drops the relay hint`() {
        val payload = tlv(0, hex(eventHex)) + tlv(1, "wss://sender-chosen.example".toByteArray())
        assertEquals(QuoteRef.EventPointer(eventHex, null), QuoteRef.eventPointerFromNeventTlv(payload))
    }

    @Test
    fun `nevent pointer needs a 32-byte id and ignores a short author`() {
        assertNull(QuoteRef.eventPointerFromNeventTlv(tlv(2, hex(authorHex))))
        val shortAuthor = tlv(0, hex(eventHex)) + tlv(2, ByteArray(20))
        assertNull(QuoteRef.eventPointerFromNeventTlv(shortAuthor)?.author)
    }
}
