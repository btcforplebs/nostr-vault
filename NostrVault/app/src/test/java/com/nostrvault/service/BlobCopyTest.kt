package com.nostrvault.service

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.IOException
import java.net.SocketTimeoutException
import java.net.UnknownHostException

/**
 * Media servers › Copy to servers says why a file did not copy. These pin
 * the words for each server answer and which failures get one more try.
 */
class BlobCopyTest {

    private fun reason(attempt: CopyAttempt) = (attempt.outcome as BlobCopyOutcome.Failed).reason

    @Test
    fun `a refused key is said plainly and tried once more with a single-file signature`() {
        val attempt = copyFailure(401, "auth event has wrong pubkey")
        assertEquals("The server turned down your key (HTTP 401). It said: \"auth event has wrong pubkey\".", reason(attempt))
        assertTrue(attempt.authRefused)
        assertFalse(attempt.worthRetry)
    }

    @Test
    fun `too big is not retried`() {
        val attempt = copyFailure(413, null)
        assertEquals("Too big for this server (HTTP 413).", reason(attempt))
        assertFalse(attempt.worthRetry)
    }

    @Test
    fun `server errors get one more try and an html body is not quoted`() {
        val attempt = copyFailure(502, "<html><body>Bad gateway</body></html>")
        assertEquals("The server had a problem (HTTP 502). Try again later.", reason(attempt))
        assertTrue(attempt.worthRetry)
    }

    @Test
    fun `network failures read as what happened`() {
        assertEquals("Couldn't find the server's address.", reason(copyFailure(UnknownHostException("x"))))
        assertEquals("The server stopped answering.", reason(copyFailure(SocketTimeoutException("x"))))
        assertTrue(copyFailure(SocketTimeoutException("x")).worthRetry)
        assertEquals("Stopped.", reason(copyFailure(IOException("Canceled"))))
    }

    @Test
    fun `content type comes from the first bytes`() {
        assertEquals("image/jpeg", sniffContentType(byteArrayOf(0xFF.toByte(), 0xD8.toByte(), 0xFF.toByte(), 0xE0.toByte())))
        assertEquals("image/png", sniffContentType(byteArrayOf(0x89.toByte(), 0x50, 0x4E, 0x47, 0x0D, 0x0A)))
        assertEquals("image/gif", sniffContentType("GIF89a".toByteArray()))
        val mov = ByteArray(4) + "ftypqt  ".toByteArray()
        assertEquals("video/quicktime", sniffContentType(mov))
        val mp4 = ByteArray(4) + "ftypisom".toByteArray()
        assertEquals("video/mp4", sniffContentType(mp4))
        assertEquals("application/octet-stream", sniffContentType(ByteArray(0)))
    }

    @Test
    fun `the batch authorisation keeps every hash as its own x tag`() {
        val event = NostrEvent(
            id = "id", pubkey = "pk", createdAt = 1, kind = 24242,
            tags = listOf(listOf("t", "upload"), listOf("x", "a".repeat(64)), listOf("x", "b".repeat(64))),
            content = "Blossom upload of 2 files", sig = "sig",
        )
        val json = eventJson(event)
        assertTrue(json.contains("[\"x\",\"${"a".repeat(64)}\"]"))
        assertTrue(json.contains("[\"x\",\"${"b".repeat(64)}\"]"))
        assertTrue(json.contains("\"created_at\":1"))
    }
}
