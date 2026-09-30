package com.nostrvault.data.model

import kotlinx.serialization.builtins.ListSerializer
import kotlinx.serialization.json.Json
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Test

/**
 * Mirrors HavenApp/MediaLogicTests/Tests/MediaLogicTests/QueuedMediaPostTests.swift.
 */
class QueuedMediaPostTest {

    private val hashA = "a".repeat(64)
    private val hashB = "b".repeat(64)

    private fun post(
        body: String = "gm #nostr",
        media: List<QueuedMediaPost.Media>,
        quoteSuffix: String? = null,
        baseTags: List<List<String>> = listOf(listOf("p", "abc")),
    ) = QueuedMediaPost(
        accountNpub = "npub1me",
        body = body,
        media = media,
        quoteSuffix = quoteSuffix,
        baseTags = baseTags,
    )

    // region Readiness

    @Test
    fun `not assembled while any attachment is only on this device`() {
        val queued = post(
            media = listOf(
                QueuedMediaPost.Media(sha256 = hashA, mimeType = "image/jpeg", url = "https://mac.example/$hashA"),
                QueuedMediaPost.Media(sha256 = hashB, mimeType = "image/png", url = null),
            )
        )
        assertFalse(queued.isReady)
        assertEquals(listOf(hashB), queued.pendingMedia.map { it.sha256 })
        assertNull(queued.assembled())
    }

    // endregion

    // region Same note as a direct post

    /**
     * The queue must publish exactly what ComposeNoteViewModel.publish() would
     * have published had the server answered first time: body, one media line
     * per attachment in order, quote reference last; base tags then `t` then
     * `imeta`.
     */
    @Test
    fun `assembles the same note as the direct path`() {
        val urlA = "https://mac.example/$hashA"
        val urlB = "https://blossom.example/$hashB"
        val quote = "\nnostr:note1quoted"
        val baseTags = listOf(
            listOf("e", "root", "", "root", "pk"),
            listOf("q", "quoted", "wss://relay", "qpk"),
            listOf("p", "qpk"),
        )
        val waiting = post(
            body = "gm #Nostr from #Ohio",
            media = listOf(
                QueuedMediaPost.Media(hashA, "image/jpeg", null, 800, 600, "a cat", 1234L),
                QueuedMediaPost.Media(hashB, "image/png", urlB, alt = ""),
            ),
            quoteSuffix = quote,
            baseTags = baseTags,
        )
        // The first attachment's server answers later.
        val queued = waiting.copy(media = waiting.media.mapIndexed { i, m -> if (i == 0) m.copy(url = urlA) else m })

        // What publish() builds on the direct path.
        val descriptors = listOf(
            NoteTagging.MediaDescriptor(urlA, "image/jpeg", hashA, 800, 600, "a cat", 1234L),
            NoteTagging.MediaDescriptor(urlB, "image/png", hashB, null, null, "", null),
        )
        var directContent = "gm #Nostr from #Ohio"
        descriptors.forEach { directContent += "\n${it.url}" }
        directContent += quote
        val directTags = baseTags.toMutableList()
        directTags.addAll(NoteTagging.hashtagTags(directContent))
        directTags.addAll(NoteTagging.imetaTags(descriptors))

        val assembled = queued.assembled()!!
        assertEquals(directContent, assembled.content)
        assertEquals(directTags, assembled.tags)
        assertEquals(2, assembled.tags.count { it.first() == "imeta" })
        assertEquals(listOf(listOf("t", "nostr"), listOf("t", "ohio")), assembled.tags.filter { it.first() == "t" })
    }

    @Test
    fun `media only post has no text line`() {
        val url = "https://mac.example/$hashA"
        val queued = post(body = "", media = listOf(QueuedMediaPost.Media(hashA, "image/jpeg", url)), baseTags = emptyList())
        assertEquals("\n$url", queued.assembled()?.content)
    }

    // endregion

    // region Survives a relaunch

    @Test
    fun `round trips through JSON`() {
        val json = Json { ignoreUnknownKeys = true; encodeDefaults = true }
        val queued = listOf(
            post(
                media = listOf(QueuedMediaPost.Media(hashA, "video/mp4", null, 1920, 1080, null, 99L)),
                quoteSuffix = "\nnostr:note1x",
            ).copy(attempts = 3, lastAttempt = 1_700_000_000_000L),
            post(body = "", media = listOf(QueuedMediaPost.Media(hashB, url = "https://b.example/$hashB"))),
        )
        val serializer = ListSerializer(QueuedMediaPost.serializer())
        val decoded = json.decodeFromString(serializer, json.encodeToString(serializer, queued))
        assertEquals(queued, decoded)
    }

    // endregion

    // region Wording

    @Test
    fun `queued message names the Mac vault`() {
        assertEquals(
            "Saved on this device. Your post will send itself as soon as your Mac vault answers.",
            MediaUploadOutcomeMessage.queued(hosts = listOf("mac.ts.net"), macHost = "mac.ts.net"),
        )
        assertEquals(
            "Saved on this device. Your post will send itself as soon as your Mac vault or another media server answers.",
            MediaUploadOutcomeMessage.queued(hosts = listOf("mac.ts.net", "blossom.example"), macHost = "mac.ts.net"),
        )
    }

    @Test
    fun `queued message names a single other server`() {
        assertEquals(
            "Saved on this device. Your post will send itself as soon as blossom.example answers.",
            MediaUploadOutcomeMessage.queued(hosts = listOf("blossom.example"), macHost = null),
        )
        assertEquals(
            "Saved on this device. Your post will send itself as soon as one of your media servers answers.",
            MediaUploadOutcomeMessage.queued(hosts = listOf("a.example", "b.example"), macHost = "mac.ts.net"),
        )
    }

    @Test
    fun `no message blames the connection`() {
        listOf(
            MediaUploadOutcomeMessage.NO_OUTSIDE_SERVER,
            MediaUploadOutcomeMessage.NOT_SAVED_ON_DEVICE,
            MediaUploadOutcomeMessage.SENT,
            MediaUploadOutcomeMessage.queued(listOf("x"), null),
            MediaUploadOutcomeMessage.queued(listOf("x", "y"), "x"),
        ).forEach { message ->
            assertFalse(message, message.contains("connection", ignoreCase = true))
        }
    }

    // endregion
}
