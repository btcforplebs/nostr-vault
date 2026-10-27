package com.nostrvault.data.model

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class LiveStatusBookTest {

    private val author = "a".repeat(64)
    private val streamer = "b".repeat(64)
    private val guest = "c".repeat(64)
    private val now = 1_700_000_000L

    private fun stream(
        createdAt: Long = now - 60,
        d: String = "show",
        status: String? = "live",
        url: String? = "https://example.com/live.m3u8",
        extra: List<List<String>> = emptyList(),
    ): LiveStream {
        val tags = mutableListOf(listOf("d", d))
        status?.let { tags.add(listOf("status", it)) }
        url?.let { tags.add(listOf("streaming", it)) }
        return LiveStream.from(author, createdAt, tags + extra)!!
    }

    @Test fun `a live playable stream makes its author live`() {
        val book = LiveStatusBook()
        assertTrue(book.ingest(stream()))
        assertEquals(setOf(author), book.liveHosts(now))
        assertEquals("show", book.liveStream(author, now)?.identifier)
    }

    @Test fun `the host tag wins over the signer and guests never count`() {
        val book = LiveStatusBook()
        book.ingest(stream(extra = listOf(
            listOf("p", streamer, "", "Host"),
            listOf("p", guest, "", "Speaker"),
        )))
        assertEquals(setOf(streamer), book.liveHosts(now))
        assertNull(book.liveStream(guest, now))
        assertNull(book.liveStream(author, now))
    }

    @Test fun `a newer ended copy replaces the live one, an older one does not`() {
        val book = LiveStatusBook()
        book.ingest(stream(createdAt = now - 60))
        assertFalse(book.ingest(stream(createdAt = now - 120, status = "ended")))
        assertEquals(setOf(author), book.liveHosts(now))
        assertTrue(book.ingest(stream(createdAt = now - 30, status = "ended")))
        assertTrue(book.liveHosts(now).isEmpty())
    }

    @Test fun `stale, ended-by-time and unplayable streams are not live`() {
        for (s in listOf(
            stream(createdAt = now - LiveStream.STALE_AFTER_SECONDS - 1),
            stream(extra = listOf(listOf("ends", "${now - 1}"))),
            stream(url = "rtmp://example.com/live"),
            stream(url = null),
            stream(status = "planned"),
        )) {
            val book = LiveStatusBook()
            book.ingest(s)
            assertTrue("$s", book.liveHosts(now).isEmpty())
        }
        val noStatus = LiveStatusBook().apply { ingest(stream(status = null)) }
        assertEquals(setOf(author), noStatus.liveHosts(now))
    }

    @Test fun `the newest of two live streams is the one opened`() {
        val book = LiveStatusBook()
        book.ingest(stream(d = "old", createdAt = now - 300))
        book.ingest(stream(d = "new", createdAt = now - 10))
        assertEquals("new", book.liveStream(author, now)?.identifier)
    }

    @Test fun `a pubkey is asked again only after the recheck window`() {
        val book = LiveStatusBook()
        val t = 1_000_000L
        assertEquals(listOf(author, streamer), book.takeDue(setOf(streamer, author), t))
        assertTrue(book.takeDue(setOf(author), t + LiveStatusBook.RECHECK_AFTER_MS - 1).isEmpty())
        assertEquals(listOf(guest), book.takeDue(setOf(author, guest), t + 1))
        assertEquals(listOf(author), book.takeDue(setOf(author), t + LiveStatusBook.RECHECK_AFTER_MS))
    }

    @Test fun `reset forgets streams and asks`() {
        val book = LiveStatusBook()
        book.ingest(stream())
        book.takeDue(setOf(author), 0)
        book.reset()
        assertTrue(book.liveHosts(now).isEmpty())
        assertEquals(listOf(author), book.takeDue(setOf(author), 1))
    }
}
