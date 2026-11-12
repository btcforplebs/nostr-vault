package com.nostrvault.data.model

import kotlinx.coroutines.runBlocking
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.int
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import kotlinx.serialization.json.long
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.util.Base64

/**
 * Drafts (kind 31234) on the vault's /private relay are NIP-37: the note's
 * text and tags NIP-44 encrypted to the author's own key, only `d` and `k`
 * outside. Drafts saved before that, in plain text, still open. iOS: DraftEnvelopeTests.
 */
class DraftEnvelopeTest {
    private val me = "a".repeat(64)
    private val secret = "meet at the old mill at 9, bring the key"
    private val draft = Draft(
        id = "DRAFT-1", content = secret, pubkey = me,
        replyToId = "b".repeat(64), rootId = "c".repeat(64),
        quoteId = "d".repeat(64), quotePubkey = "e".repeat(64),
        updatedAt = 1_790_000_000_123,
    )

    /** A stand-in for NIP-44 to self, v2-shaped (base64, first byte 2), that keeps nothing readable. */
    private fun fakeEncrypt(plain: String): String {
        val body = plain.toByteArray().map { (it.toInt() xor 0x5A).toByte() }
        val bytes = byteArrayOf(2) + ByteArray(32) { 0x11 } + body.toByteArray() +
            ByteArray(maxOf(0, 99 - 33 - body.size - 2)) { 0x22 } +
            byteArrayOf((body.size shr 8).toByte(), body.size.toByte())
        return Base64.getEncoder().encodeToString(bytes)
    }

    private fun fakeDecrypt(payload: String): String? {
        val b = runCatching { Base64.getDecoder().decode(payload) }.getOrNull() ?: return null
        if (b.size < 99 || b[0].toInt() != 2) return null
        val len = (b[b.size - 2].toInt() and 0xff shl 8) or (b[b.size - 1].toInt() and 0xff)
        return String(b.copyOfRange(33, 33 + len).map { (it.toInt() xor 0x5A).toByte() }.toByteArray())
    }

    private fun seal(encrypt: suspend (String) -> String? = { fakeEncrypt(it) }) =
        runBlocking { DraftEvents.seal(draft.content, DraftEvents.tags(draft), draft.updatedAt, encrypt) }

    /** The text never leaves the app: not in the content, not in a tag. */
    @Test fun aSealedDraftCarriesNoPlaintext() {
        val sealed = seal()!!
        assertFalse(sealed.content.contains("old mill"))
        assertTrue(DraftEvents.looksEncrypted(sealed.content))
        assertFalse(sealed.tags.flatten().any { it.contains("old mill") })
    }

    /** Who it answers and quotes stays inside too: only d and k are outside. */
    @Test fun onlyDAndKAreLeftOutside() {
        assertEquals(listOf(listOf("d", "DRAFT-1"), listOf("k", "1")), seal()!!.tags)
    }

    /** Inside is NIP-37's draft event: kind, content, tags (not d/k), created_at in seconds. */
    @Test fun insideIsTheDraftEvent() {
        var inner = ""
        seal { inner = it; fakeEncrypt(it) }
        val obj = Json.parseToJsonElement(inner).jsonObject
        assertEquals(1, obj["kind"]!!.jsonPrimitive.int)
        assertEquals(secret, obj["content"]!!.jsonPrimitive.content)
        assertEquals(1_790_000_000L, obj["created_at"]!!.jsonPrimitive.long)
        val tags = obj["tags"]!!.jsonArray.map { t -> t.jsonArray.map { it.jsonPrimitive.content } }
        assertEquals(DraftEvents.tags(draft).drop(2), tags)
    }

    /** A failed (or empty) encryption sends nothing in its place. */
    @Test fun aFailedEncryptionSealsNothing() {
        assertNull(seal { null })
        assertNull(seal { "" })
    }

    /** Saved and fetched back: the same text, tags in the old shape, and the time it was saved. */
    @Test fun aRoundTripGivesTheDraftBack() {
        val sealed = seal()!!
        val opened = runBlocking { DraftEvents.open(sealed.content, sealed.tags) { fakeDecrypt(it) } }!!
        assertEquals(secret, opened.content)
        assertEquals(DraftEvents.tags(draft), opened.tags)
        assertEquals(1_790_000_000L, opened.createdAt)
        assertFalse(opened.wasPlaintext)
        val back = DraftEvents.fromEvent(opened.content, me, opened.tags, opened.createdAt!!)!!
        assertEquals(draft.replyToId, back.replyToId)
        assertEquals(draft.rootId, back.rootId)
        assertEquals(draft.quoteId, back.quoteId)
        assertEquals(draft.quotePubkey, back.quotePubkey)
    }

    /** A draft saved before encryption opens as it was, marked to be saved again; nothing is decrypted. */
    @Test fun anOldPlaintextDraftStillOpens() {
        var asked = false
        val tags = DraftEvents.tags(draft)
        val opened = runBlocking { DraftEvents.open(secret, tags) { asked = true; fakeDecrypt(it) } }!!
        assertEquals(secret, opened.content)
        assertEquals(tags, opened.tags)
        assertNull(opened.createdAt)
        assertTrue(opened.wasPlaintext)
        assertFalse(asked)
    }

    @Test fun shortAndEmptyOldDraftsArePlaintext() {
        for (text in listOf("", "x", "hello", "QUJD", "A".repeat(131))) {
            val opened = runBlocking { DraftEvents.open(text, listOf(listOf("d", "1"))) { "" } }
            assertNotNull(text, opened)
            assertEquals(text, opened!!.content)
            assertTrue(text, opened.wasPlaintext)
        }
    }

    /**
     * The one rule both apps use (iOS DraftEnvelopeTests.testSharedDetectionVectors,
     * same list): a miss shows ciphertext as text and saves it again, so
     * anything shaped like a NIP-44 payload counts, padded or not.
     */
    @Test fun sharedDetectionVectors() {
        val payload = "AgMKERgfJi00O0JJUFdeZWxzeoGIj5adpKuyucDHztXc4+rx+P8GDRQbIikwNz5FTFNaYWhvdn2Ei5KZoKeutbzDytHY3+bt9PsCCRAXHiUsMzpBSE9WXWRrcnmAh46VnKOqsbg="
        val vectors = listOf(
            payload to true,
            payload.trimEnd('=') to true, // a signer that drops the padding
            "$payload\n" to true,
            "  $payload\r\n" to true,
            "A".repeat(131) to false,
            "A".repeat(132) to true,
            "A".repeat(133) to false, // not a base64 length
            "A".repeat(87_472) to true,
            "A".repeat(87_473) to false,
            payload.replaceRange(60, 61, " ") to false,
            payload.replaceRange(60, 61, "-") to false, // URL-safe alphabet is not NIP-44
            payload.replaceRange(60, 61, "=") to false,
            "$payload=" to false,
            "meet at the old mill at 9, bring the key. ".repeat(5) to false,
        )
        for ((text, expected) in vectors) assertEquals(text.take(40), expected, DraftEvents.looksEncrypted(text))
    }

    /** Shaped like a payload but it won't open: left out, never shown and never re-saved. */
    @Test fun anUnpaddedOrUnreadablePayloadIsNeverResaved() {
        val unpadded = seal()!!.content.trimEnd('=')
        val events = listOf(DraftEvents.Fetched("ID1", unpadded, me, listOf(listOf("d", "X"), listOf("k", "1")), 1))
        val (drafts, old) = runBlocking { DraftEvents.openAll(events) { null } }
        assertTrue(drafts.isEmpty())
        assertTrue(old.isEmpty())
    }

    /** Opened once per event id: the next fetch asks the signer only for what changed. */
    @Test fun aFetchDecryptsOnlyNewEvents() {
        val sealed = seal()!!
        val events = listOf(DraftEvents.Fetched("ID1", sealed.content, me, sealed.tags, 1))
        val cache = mutableMapOf<String, DraftEvents.Opened>()
        var asked = 0
        repeat(3) { runBlocking { DraftEvents.openAll(events, cache) { asked++; fakeDecrypt(it) } } }
        assertEquals(1, asked)
        // One that didn't open is asked again; one the relay no longer has leaves the cache.
        runBlocking { DraftEvents.openAll(listOf(DraftEvents.Fetched("ID2", sealed.content, me, sealed.tags, 1)), cache) { null } }
        assertTrue(cache.isEmpty())
    }

    /**
     * Tron on PR 1968: re-saving an old iPhone/Mac draft here kept only d, k,
     * e and q, and the stripped copy then replaced the draft on both apps.
     * The tags it came with go inside as they are.
     */
    @Test fun anIPhoneDraftKeepsItsTagsWhenSavedHere() {
        val iphoneTags = listOf(
            listOf("d", "IPHONE-1"), listOf("k", "1"),
            listOf("e", "a".repeat(64), "wss://relay.one", "root"),
            listOf("e", "b".repeat(64), "wss://10.0.0.1:3355", "reply"),
            listOf("p", "c".repeat(64)),
            listOf("p", "f".repeat(64)),
        )
        val fetched = DraftEvents.fromEvent("reply text", me, iphoneTags, 1_700_000_000)!!
        val saved = DraftEvents.tagsToSave(fetched)
        assertEquals(iphoneTags, saved)
        val sealed = runBlocking { DraftEvents.seal(fetched.content, saved, fetched.updatedAt) { fakeEncrypt(it) } }!!
        val reopened = runBlocking { DraftEvents.open(sealed.content, sealed.tags) { fakeDecrypt(it) } }!!
        assertEquals(iphoneTags, reopened.tags)
        // A draft written here has no tags of its own: built from its fields, as before.
        assertEquals(DraftEvents.tags(draft), DraftEvents.tagsToSave(draft))
        // An old draft with no k tag still goes out with one.
        val noK = fetched.copy(tags = iphoneTags.filter { it[0] != "k" })
        assertEquals(listOf("k", "1"), DraftEvents.tagsToSave(noK)[1])
    }

    /** A fetch: encrypted drafts open with their saved time, old ones open and are named for a re-save, unreadable ones are dropped. */
    @Test fun aFetchOpensEachAndNamesTheOldOnes() {
        val sealed = seal()!!
        val events = listOf(
            DraftEvents.Fetched("E1", sealed.content, me, sealed.tags, createdAt = 1_800_000_000),
            DraftEvents.Fetched("E2", "old text", me, listOf(listOf("d", "OLD"), listOf("k", "1")), createdAt = 1_700_000_000),
            DraftEvents.Fetched("E3", sealed.content, me, listOf(listOf("d", "LOCKED"), listOf("k", "1")), createdAt = 1_700_000_000),
        )
        val (drafts, old) = runBlocking {
            DraftEvents.openAll(events) { c -> fakeDecrypt(c)?.takeIf { events.indexOfFirst { it.content == c } >= 0 } }
        }.let { r -> r.first.filter { it.id != "LOCKED" } to r.second }
        assertEquals(listOf("DRAFT-1", "OLD"), drafts.map { it.id })
        assertEquals(secret, drafts[0].content)
        assertEquals(1_790_000_000_000, drafts[0].updatedAt)
        assertEquals("old text", drafts[1].content)
        assertEquals(1_700_000_000_000, drafts[1].updatedAt)
        assertEquals(setOf("OLD"), old)
        val (none, _) = runBlocking { DraftEvents.openAll(events.take(1)) { null } }
        assertTrue(none.isEmpty())
    }
}
