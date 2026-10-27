package com.nostrvault.data.model

import com.nostrvault.relay.HavenBridge
import com.nostrvault.ui.components.ContentSegment
import com.nostrvault.ui.components.parseContentSegments
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * `nevent1…`, `nprofile1…` and `naddr1…` written without `nostr:` draw the
 * same quote card or mention as the prefixed form, and pasting any of them
 * into search opens what they name (iOS BareReferenceTests, #1250).
 */
class BareNostrRefsTest {
    private val id = "a".repeat(64)
    private val pubkey = "b".repeat(64)

    private val note = bech32("note", ByteArray(32) { 0xAA.toByte() })
    private val nevent = HavenBridge.encodeNevent(id, pubkey, 1)!!
    private val npub = HavenBridge.encodeNpub(pubkey)!!
    private val nprofile = HavenBridge.encodeNprofile(pubkey, listOf("wss://r.example"))!!
    private val naddr = HavenBridge.encodeNaddr("my-article", pubkey, 30023)!!

    // ── Content split ──

    @Test fun `bare references get the prefix`() {
        assertEquals("look nostr:$nevent here", BareNostrRefs.prefixBare("look $nevent here"))
        assertEquals("by nostr:$nprofile.", BareNostrRefs.prefixBare("by $nprofile."))
        assertEquals("nostr:$naddr", BareNostrRefs.prefixBare(naddr))
        assertEquals("nostr:$note\n", BareNostrRefs.prefixBare("$note\n"))
    }

    @Test fun `at before a bare profile is dropped`() {
        assertEquals("hi nostr:$npub!", BareNostrRefs.prefixBare("hi @$npub!"))
    }

    @Test fun `prefixed references are left alone`() {
        val text = "nostr:$nevent and nostr:$nprofile"
        assertEquals(text, BareNostrRefs.prefixBare(text))
    }

    @Test fun `reference inside a URL stays in the URL`() {
        val text = "https://njump.me/$nevent and https://x.com/?p=$npub"
        assertEquals(text, BareNostrRefs.prefixBare(text))
    }

    @Test fun `words that only look like references stay text`() {
        assertEquals("note1st thing, npub1abc", BareNostrRefs.prefixBare("note1st thing, npub1abc"))
        val broken = nevent.dropLast(1) + (if (nevent.last() == 'q') "p" else "q")
        assertEquals(broken, BareNostrRefs.prefixBare(broken))
    }

    @Test fun `nsec is never touched`() {
        val nsec = HavenBridge.encodeNsec(id)!!
        assertEquals("oops $nsec", BareNostrRefs.prefixBare("oops $nsec"))
        assertNull(BareNostrRefs.target(nsec))
    }

    @Test fun `bare quotes are found alongside prefixed ones`() {
        assertEquals(listOf(nevent, note, naddr), QuoteRef.identifiers("a $nevent b nostr:$note c $naddr"))
    }

    @Test fun `bare profile renders as a mention and bare quote leaves the text`() {
        val segments = parseContentSegments("Credit to $nprofile for this:\n$nevent", emptySet())
        val mention = segments.filterIsInstance<ContentSegment.Mention>().single()
        assertEquals(pubkey, mention.pubkey)
        val text = segments.filterIsInstance<ContentSegment.PlainText>().joinToString("") { it.text }
        assertTrue(text, "nevent1" !in text && "nprofile1" !in text)
    }

    // ── Search parse ──

    @Test fun `pasted references open what they name`() {
        val coordinate = QuoteRef.Coordinate(30023, pubkey, "my-article")
        val cases = listOf(
            note to BareNostrRefs.Target.Note(id),
            nevent to BareNostrRefs.Target.Note(id),
            "nostr:$nevent" to BareNostrRefs.Target.Note(id),
            "  $nevent\n" to BareNostrRefs.Target.Note(id),
            naddr to BareNostrRefs.Target.Address(naddr, coordinate),
            "nostr:$naddr" to BareNostrRefs.Target.Address(naddr, coordinate),
            npub to BareNostrRefs.Target.Profile(pubkey),
            "@$npub" to BareNostrRefs.Target.Profile(pubkey),
            nprofile to BareNostrRefs.Target.Profile(pubkey),
            "nostr:$nprofile" to BareNostrRefs.Target.Profile(pubkey),
            nprofile.uppercase() to BareNostrRefs.Target.Profile(pubkey),
        )
        for ((pasted, expected) in cases) assertEquals(pasted, expected, BareNostrRefs.pastedTarget(pasted))
    }

    @Test fun `ordinary searches are not references`() {
        for (query in listOf("jack", "notebook", "note1st", "#bitcoin", "https://example.com", "nevent1zzzz", "")) {
            assertNull(query, BareNostrRefs.pastedTarget(query))
        }
    }

    /** BIP-173 bech32, for a `note1` (HavenBridge only decodes those). */
    private fun bech32(hrp: String, data: ByteArray): String {
        val charset = "qpzry9x8gf2tvdw0s3jn54khce6mua7l"
        val words = mutableListOf<Int>()
        var acc = 0; var bits = 0
        for (b in data) {
            acc = (acc shl 8) or (b.toInt() and 0xff); bits += 8
            while (bits >= 5) { bits -= 5; words.add((acc shr bits) and 31) }
        }
        if (bits > 0) words.add((acc shl (5 - bits)) and 31)
        fun polymod(values: List<Int>): Int {
            val gen = intArrayOf(0x3b6a57b2, 0x26508e6d, 0x1ea119fa, 0x3d4233dd, 0x2a1462b3)
            var chk = 1
            for (v in values) {
                val top = chk ushr 25
                chk = ((chk and 0x1ffffff) shl 5) xor v
                for (i in 0 until 5) if ((top ushr i) and 1 == 1) chk = chk xor gen[i]
            }
            return chk
        }
        val expanded = hrp.map { it.code ushr 5 } + 0 + hrp.map { it.code and 31 }
        val mod = polymod(expanded + words + List(6) { 0 }) xor 1
        val checksum = List(6) { (mod ushr (5 * (5 - it))) and 31 }
        return hrp + "1" + (words + checksum).joinToString("") { charset[it].toString() }
    }
}
