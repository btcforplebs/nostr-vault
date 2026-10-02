package com.nostrvault.service

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/** The Media tab's cloud x/y badge reads these two decisions; they match iOS. */
class BlossomBackupSummaryTest {

    @Test
    fun `a 200 web page is not the file`() {
        assertEquals(BlobPresence.ABSENT, blobPresence(200, "text/html; charset=utf-8", "512"))
        assertEquals(BlobPresence.ABSENT, blobPresence(200, "image/jpeg", "0"))
        assertEquals(BlobPresence.PRESENT, blobPresence(200, "image/jpeg", "48213"))
        assertEquals(BlobPresence.PRESENT, blobPresence(200, null, null))
    }

    @Test
    fun `4xx is absent, 5xx is unknown`() {
        assertEquals(BlobPresence.ABSENT, blobPresence(404, null, null))
        assertEquals(BlobPresence.UNREACHABLE, blobPresence(502, null, null))
    }

    @Test
    fun `summary counts present, unreachable and missing`() {
        val mirrors = listOf("https://a", "https://b", "https://c")
        val s = BlossomBackupSummary.of(
            mapOf(
                "https://a" to BlobPresence.PRESENT,
                "https://b" to BlobPresence.ABSENT,
                "https://c" to BlobPresence.UNREACHABLE,
            ),
            mirrors,
        )!!
        assertEquals(1, s.present)
        assertEquals(1, s.unreachable)
        assertEquals(listOf("https://b", "https://c"), s.missing)
        assertTrue(s.needsMirror)
        assertFalse(s.isComplete)
    }

    @Test
    fun `a server with no answer yet leaves the summary unknown`() {
        val mirrors = listOf("https://a", "https://new")
        assertNull(BlossomBackupSummary.of(mapOf("https://a" to BlobPresence.PRESENT), mirrors))
        assertNull(BlossomBackupSummary.of(null, mirrors))
    }

    @Test
    fun `every server holding it is complete`() {
        val mirrors = listOf("https://a", "https://b")
        val s = BlossomBackupSummary.of(mirrors.associateWith { BlobPresence.PRESENT }, mirrors)!!
        assertTrue(s.isComplete)
        assertFalse(s.needsMirror)
    }
}
