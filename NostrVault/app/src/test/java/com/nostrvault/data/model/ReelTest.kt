package com.nostrvault.data.model

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.util.Date

/** Reel extraction: which URL in an event is the video, and which events must not autoplay. */
class ReelTest {

    private fun note(
        kind: Int = 1,
        content: String = "",
        tags: List<List<String>> = emptyList(),
        mediaURLs: List<String> = emptyList(),
        id: String = "id-$kind",
    ) = FeedNote(
        id = id,
        pubkey = "alice",
        content = content,
        createdAt = Date(1_000_000L),
        tags = tags,
        kind = kind,
        repostedBy = null,
        isReply = false,
        replyToPubkey = null,
        parentEventId = null,
        mediaURLs = mediaURLs,
        linkURLs = emptyList(),
        quotedEventIds = emptyList(),
        repostedEventId = null,
    )

    @Test
    fun `NIP-71 event reads url, mime, poster, shape and title from imeta`() {
        val reel = Reel.from(
            note(
                kind = 22,
                content = "a short one",
                tags = listOf(
                    listOf("title", "  Sunset  "),
                    listOf(
                        "imeta",
                        "url https://cdn.example/abc",
                        "m video/mp4",
                        "dim 1080x1920",
                        "image https://cdn.example/poster.jpg",
                        "image https://cdn.example/second.jpg",
                    ),
                ),
            ),
            createdAt = 100,
        )
        assertNotNull(reel)
        reel!!
        assertEquals("https://cdn.example/abc", reel.videoUrl)
        assertEquals("video/mp4", reel.mimeType)
        assertEquals("https://cdn.example/poster.jpg", reel.posterUrl) // first value wins
        assertEquals(0.5625f, reel.aspectRatio!!, 0.0001f)
        assertEquals("Sunset", reel.title)
        assertEquals("a short one", reel.caption)
    }

    @Test
    fun `kind-1 note with a video extension becomes a reel and the link leaves the caption`() {
        val url = "https://files.example/clip.mp4"
        val reel = Reel.from(
            note(content = "look at this $url", mediaURLs = listOf("https://files.example/pic.jpg", url)),
            createdAt = 5,
        )
        assertEquals(url, reel?.videoUrl)
        assertEquals("look at this", reel?.caption)
        assertNull(reel?.mimeType)
    }

    @Test
    fun `kind-1 note with an extensionless link counts only when imeta says video`() {
        val blossom = "https://blossom.example/" + "a".repeat(64)
        val tagged = note(
            content = blossom,
            tags = listOf(listOf("imeta", "url $blossom", "m video/quicktime")),
            mediaURLs = listOf(blossom),
        )
        assertEquals(blossom, Reel.from(tagged, 1)?.videoUrl)
        assertEquals("video/quicktime", Reel.from(tagged, 1)?.mimeType)

        val untagged = note(content = blossom, mediaURLs = listOf(blossom))
        assertNull(Reel.from(untagged, 1))
    }

    @Test
    fun `a content type learned elsewhere lets an extensionless link through`() {
        val blossom = "https://blossom.example/" + "b".repeat(64)
        val reel = Reel.from(note(content = blossom, mediaURLs = listOf(blossom)), 1) { url ->
            if (url == blossom) "video/mp4" else null
        }
        assertEquals(blossom, reel?.videoUrl)
    }

    @Test
    fun `an explicit image type beats a video-looking path`() {
        val url = "https://cdn.example/thumb.mp4"
        val reel = Reel.from(
            note(tags = listOf(listOf("imeta", "url $url", "m image/jpeg")), mediaURLs = emptyList()),
            1,
        )
        assertNull(reel)
    }

    @Test
    fun `images only is not a reel`() {
        assertNull(Reel.from(note(content = "x", mediaURLs = listOf("https://x.example/a.png")), 1))
    }

    @Test
    fun `content warning keeps a note out of Reels`() {
        val reel = Reel.from(
            note(
                content = "https://x.example/a.mp4",
                tags = listOf(listOf("content-warning", "nsfw")),
                mediaURLs = listOf("https://x.example/a.mp4"),
            ),
            1,
        )
        assertNull(reel)
        // A bare tag with no reason counts too.
        assertNull(
            Reel.from(
                note(kind = 21, tags = listOf(listOf("content-warning"), listOf("url", "https://x.example/v"))),
                1,
            ),
        )
    }

    @Test
    fun `older NIP-71 events with a bare url tag still play`() {
        val reel = Reel.from(
            note(kind = 34235, tags = listOf(listOf("url", "https://x.example/v"), listOf("m", "video/webm"))),
            1,
        )
        assertEquals("https://x.example/v", reel?.videoUrl)
        assertEquals("video/webm", reel?.mimeType)
    }

    @Test
    fun `a bare url tag on a kind-1 note is not taken as video`() {
        assertNull(Reel.from(note(kind = 1, tags = listOf(listOf("url", "https://x.example/v"))), 1))
    }

    @Test
    fun `non-http links are skipped`() {
        val reel = Reel.from(
            note(
                kind = 21,
                tags = listOf(
                    listOf("imeta", "url ipfs://bafy/clip.mp4", "m video/mp4"),
                    listOf("imeta", "url https://gw.example/clip.mp4", "m video/mp4"),
                ),
            ),
            1,
        )
        assertEquals("https://gw.example/clip.mp4", reel?.videoUrl)
    }

    @Test
    fun `dim parsing rejects nonsense`() {
        assertEquals(1.7778f, Reel.aspectFromDim("1920X1080")!!, 0.001f)
        assertNull(Reel.aspectFromDim("1920"))
        assertNull(Reel.aspectFromDim("0x1080"))
        assertNull(Reel.aspectFromDim("wide"))
    }

    @Test
    fun `fill when the shapes are within the tolerance, fit otherwise`() {
        val phone = 9f / 19.5f
        assertTrue(Reel.fillsScreen(9f / 16f, phone)) // portrait clip on a phone
        assertFalse(Reel.fillsScreen(16f / 9f, phone)) // landscape clip on a phone
        assertFalse(Reel.fillsScreen(9f / 16f, 3f / 4f)) // phone clip on a tablet
        assertFalse(Reel.fillsScreen(null, phone)) // unknown shape fits
    }

    @Test
    fun `newest first with id as the tie-break`() {
        fun reel(id: String, at: Long) = Reel.from(
            note(id = id, content = "https://x.example/$id.mp4", mediaURLs = listOf("https://x.example/$id.mp4")),
            at,
        )!!
        val sorted = listOf(reel("a", 1), reel("c", 2), reel("b", 2)).sortedWith(Reel.NEWEST_FIRST)
        assertEquals(listOf("c", "b", "a"), sorted.map { it.id })
    }

    @Test
    fun `stream by kind`() {
        assertEquals(ReelStream.NOTE, ReelStream.forKind(1))
        Reel.VIDEO_KINDS.forEach { assertEquals(ReelStream.VIDEO, ReelStream.forKind(it)) }
        assertNull(ReelStream.forKind(6))
    }
}
