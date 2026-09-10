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

    private companion object {
        // Realistic lengths: the extractor requires a plausible bech32 body so a
        // bare word in prose cannot be mistaken for a reference.
        const val CHARSET = "qpzry9x8gf2tvdw0s3jn54khce6mua7l"
        const val NOTE1 = "note1$CHARSET$CHARSET"
        const val NEVENT1 = "nevent1$CHARSET$CHARSET"
        const val NADDR1 = "naddr1$CHARSET$CHARSET"
        const val UNKNOWN = "note1" + "lllllllllllllllllllllllllllllll"
    }

    private val eventHex = "a".repeat(64)
    private val otherHex = "b".repeat(64)
    private val authorHex = "c".repeat(64)

    /** Decodes by prefix alone, so the tests need no bech32 and no native library. */
    private val decoder = object : QuoteRef.Decoder {
        override fun noteToHex(note1: String) =
            if (note1 == NOTE1) eventHex else null

        override fun neventToHex(nevent1: String) =
            if (nevent1 == NEVENT1) otherHex else null

        override fun naddrToCoordinate(naddr1: String) =
            if (naddr1 == NADDR1) QuoteRef.Coordinate(30023, authorHex, "my-post") else null
    }

    // ── The regression: parser output must be fetcher input ──────────

    @Test
    fun `every key the parser produces is a key the fetcher can read`() {
        val content = "look $NOTE1 and $NEVENT1 and $NADDR1"

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
        assertNull(QuoteRef.key("$NOTE1"))
        assertNull(QuoteRef.key(""))
        assertNull(QuoteRef.key("zz" + "a".repeat(62)))
    }

    // ── naddr ────────────────────────────────────────────────────────

    @Test
    fun `an naddr resolves to its coordinate`() {
        assertEquals(
            listOf("naddr:30023:$authorHex:my-post"),
            QuoteRef.resolvedIdentifiers("read $NADDR1", decoder),
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
        val content = "$NEVENT1 then $NOTE1 then $NEVENT1 again"
        assertEquals(listOf(NEVENT1, NOTE1), QuoteRef.identifiers(content))
    }

    @Test
    fun `a reference that will not decode is dropped, not passed through`() {
        // Passing the bech32 through is the original bug: it asked the relay
        // for an id that cannot exist.
        assertEquals(emptyList<String>(), QuoteRef.resolvedIdentifiers("$UNKNOWN", decoder))
    }

    @Test
    fun `profile mentions are not quote references`() {
        assertEquals(emptyList<String>(), QuoteRef.identifiers("hi nostr:npub1aaa and nostr:nprofile1bbb"))
    }

    // ── Bare references (no "nostr:" prefix) ────────────────────────

    @Test
    fun `a bare reference with no nostr prefix is still a quote`() {
        // Clients in the wild post these. Rendered as raw text they look like
        // our bug, not theirs.
        assertEquals(listOf(NEVENT1), QuoteRef.identifiers("look at this $NEVENT1"))
    }

    @Test
    fun `a bare reference at the very start of a note is found`() {
        assertEquals(listOf(NEVENT1), QuoteRef.identifiers(NEVENT1))
    }

    @Test
    fun `a reference inside a url path is left alone`() {
        // njump-style links are ordinary links; turning one into a card would
        // swallow the URL the author meant to show.
        assertEquals(emptyList<String>(), QuoteRef.identifiers("https://njump.me/$NEVENT1"))
    }

    @Test
    fun `a reference glued to the end of a word is not a reference`() {
        assertEquals(emptyList<String>(), QuoteRef.identifiers("xyz$NEVENT1"))
    }

    @Test
    fun `a short lookalike is not a reference`() {
        // "note1" followed by a couple of characters is prose, not bech32.
        assertEquals(emptyList<String>(), QuoteRef.identifiers("note1a and nevent1b"))
    }

    @Test
    fun `the nostr prefix is consumed, not captured`() {
        assertEquals(listOf(NOTE1), QuoteRef.identifiers("nostr:$NOTE1"))
    }

    // ── Relay hints ─────────────────────────────────────────────────

    @Test
    fun `relay hints are keyed by the same lookup key`() {
        val hinting = object : QuoteRef.Decoder by decoder {
            override fun relayHints(identifier: String) =
                if (identifier == NADDR1) listOf("wss://hint.example") else emptyList()
        }
        val hints = QuoteRef.relayHints("read $NADDR1", hinting)
        assertEquals(
            mapOf("naddr:30023:$authorHex:my-post" to listOf("wss://hint.example")),
            hints,
        )
    }

    @Test
    fun `a reference with no hint contributes no entry`() {
        assertEquals(emptyMap<String, List<String>>(), QuoteRef.relayHints("read $NADDR1", decoder))
    }

    @Test
    fun `two references to the same event yield one key`() {
        val content = "$NOTE1 and again $NOTE1"
        assertEquals(listOf(eventHex), QuoteRef.resolvedIdentifiers(content, decoder))
    }
}
