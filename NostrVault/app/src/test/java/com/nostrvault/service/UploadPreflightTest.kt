package com.nostrvault.service

import com.nostrvault.data.model.QueuedMediaPost
import com.nostrvault.data.model.WaitingPostStopReason
import com.nostrvault.data.model.resetForUserRetry
import kotlinx.serialization.json.Json
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/** BUD-06 pre-check and the refusal reason (NDK check step 3, Logen 2026-11-04). Same rules as iOS preflightCheck. */
class UploadPreflightTest {
    @Test fun `only a real no stops the upload`() {
        for (code in listOf(200, 204, 404, 405, 408, 429, 500, 502, 503)) assertTrue("$code", UploadPreflight.allows(code))
        for (code in listOf(400, 401, 402, 403, 411, 413, 415)) assertFalse("$code", UploadPreflight.allows(code))
    }

    @Test fun `refusals keep the server's reason until taken`() {
        val sha = "f".repeat(64)
        BlossomRefusals.clear(sha)
        BlossomRefusals.record(sha, "https://a.example", 413, "  file too large, max 50 MB ")
        BlossomRefusals.record(sha, "https://b.example", 403, "")
        assertEquals(mapOf("https://a.example" to "file too large, max 50 MB"), BlossomRefusals.takeReasons(sha))
        assertEquals(mapOf("https://a.example" to 413, "https://b.example" to 403), BlossomRefusals.take(sha))
        assertTrue(BlossomRefusals.takeReasons(sha).isEmpty())
    }

    private fun post(status: Int?, reason: String?) = QueuedMediaPost(
        createdAt = 1L, accountNpub = "npub1test", body = "gm",
        media = listOf(QueuedMediaPost.Media(sha256 = "a".repeat(64))), baseTags = emptyList(),
        refusedStatus = status, refusedReason = reason,
    )

    @Test fun `the waiting post says why`() {
        assertEquals(
            "Stopped: every media server refused this file (HTTP 413: file too large, max 50 MB). Try sending now, or add another server.",
            WaitingPostStopReason.of(post(413, "file too large, max 50 MB")),
        )
        assertEquals(
            "Stopped: every media server refused this file (HTTP 403). Try sending now, or add another server.",
            WaitingPostStopReason.of(post(403, null)),
        )
        val retried = post(413, "too big").resetForUserRetry()
        assertNull(retried.refusedStatus)
        assertNull(retried.refusedReason)
    }

    @Test fun `posts saved before the reason still load`() {
        val json = Json { ignoreUnknownKeys = true }
        val saved = json.encodeToString(QueuedMediaPost.serializer(), post(403, null)).replace(",\"refusedReason\":null", "")
        assertNull(json.decodeFromString(QueuedMediaPost.serializer(), saved).refusedReason)
    }
}
