package com.nostrvault.data.model

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Test

/**
 * Mirrors HavenApp/MediaLogicTests/Tests/MediaLogicTests/NoteTaggingTests.swift —
 * if a rule changes on one platform it should fail here too.
 */
class NoteTaggingTest {

    // region Hashtags

    @Test
    fun `extracts hashtags in order without the hash`() {
        assertEquals(listOf("nostr", "bitcoin"), NoteTagging.hashtags("gm #nostr and #bitcoin"))
    }

    @Test
    fun `lowercases and deduplicates case insensitively`() {
        assertEquals(listOf("bitcoin"), NoteTagging.hashtags("#Bitcoin #bitcoin #BITCOIN"))
    }

    @Test
    fun `ignores fragments inside urls`() {
        assertEquals(
            listOf("help"),
            NoteTagging.hashtags("see https://example.com/docs#installation for #help"),
        )
    }

    @Test
    fun `ignores nostr and relay references`() {
        assertEquals(
            listOf("tag"),
            NoteTagging.hashtags("wss://relay.example/#room nostr:npub1abc#x plain #tag"),
        )
    }

    @Test
    fun `ignores a hash that follows a word character`() {
        assertEquals(emptyList<String>(), NoteTagging.hashtags("I write C# daily"))
        assertEquals(emptyList<String>(), NoteTagging.hashtags("a#b"))
    }

    @Test
    fun `requires a letter so digit only runs are not tags`() {
        assertEquals(emptyList<String>(), NoteTagging.hashtags("we are #1 today"))
        assertEquals(listOf("nostr2"), NoteTagging.hashtags("#nostr2"))
    }

    @Test
    fun `strips surrounding punctuation`() {
        assertEquals(
            listOf("nostr", "bitcoin", "freedom"),
            NoteTagging.hashtags("(#nostr), #bitcoin. #freedom!"),
        )
    }

    @Test
    fun `matches non latin hashtags`() {
        assertEquals(listOf("日本"), NoteTagging.hashtags("おはよう #日本"))
    }

    @Test
    fun `skips runs longer than the length guard`() {
        val long = "a".repeat(65)
        assertEquals(listOf("ok"), NoteTagging.hashtags("#$long #ok"))
    }

    @Test
    fun `builds t tags`() {
        assertEquals(
            listOf(listOf("t", "nostr"), listOf("t", "bitcoin")),
            NoteTagging.hashtagTags("#nostr #bitcoin"),
        )
    }

    // endregion

    // region imeta

    @Test
    fun `imeta carries every known field in nip92 order`() {
        val media = NoteTagging.MediaDescriptor(
            url = "https://blossom.example/abc.jpg",
            mimeType = "image/jpeg",
            sha256 = "deadbeef",
            pixelWidth = 3024,
            pixelHeight = 4032,
            alt = "A cat asleep on a keyboard",
            byteCount = 120_000L,
        )
        assertEquals(
            listOf(
                "imeta",
                "url https://blossom.example/abc.jpg",
                "m image/jpeg",
                "x deadbeef",
                "dim 3024x4032",
                "size 120000",
                "alt A cat asleep on a keyboard",
            ),
            NoteTagging.imetaTag(media),
        )
    }

    @Test
    fun `imeta omits unknown fields rather than emitting them empty`() {
        assertEquals(
            listOf("imeta", "url https://blossom.example/abc.jpg"),
            NoteTagging.imetaTag(NoteTagging.MediaDescriptor(url = "https://blossom.example/abc.jpg")),
        )
    }

    @Test
    fun `imeta omits dim when only one axis is known`() {
        val media = NoteTagging.MediaDescriptor(
            url = "https://blossom.example/abc.jpg",
            pixelWidth = 100,
        )
        assertFalse(NoteTagging.imetaTag(media)!!.any { it.startsWith("dim ") })
    }

    @Test
    fun `imeta flattens newlines in alt`() {
        val media = NoteTagging.MediaDescriptor(
            url = "https://blossom.example/abc.jpg",
            alt = "line one\nline two",
        )
        assertEquals("alt line one line two", NoteTagging.imetaTag(media)!!.last())
    }

    @Test
    fun `descriptor without a url produces no tag`() {
        assertNull(NoteTagging.imetaTag(NoteTagging.MediaDescriptor(url = "   ")))
    }

    // endregion
}
