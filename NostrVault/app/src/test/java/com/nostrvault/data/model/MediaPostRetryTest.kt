package com.nostrvault.data.model

import kotlinx.serialization.json.Json
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/** Mirrors HavenApp/MediaLogicTests/Tests/MediaLogicTests/MediaPostRetryTests.swift. */
class MediaPostRetryTest {

    private fun post(
        attempts: Int = 0,
        lastAttempt: Long? = null,
        refusedStatus: Int? = null,
        bytes: List<Long?> = listOf(500_000L),
    ) = QueuedMediaPost(
        createdAt = 1_000L,
        accountNpub = "npub1test",
        body = "gm",
        media = bytes.mapIndexed { i, b -> QueuedMediaPost.Media(sha256 = "$i".repeat(64), byteCount = b) },
        baseTags = emptyList(),
        attempts = attempts,
        lastAttempt = lastAttempt,
        refusedStatus = refusedStatus,
    )

    @Test fun `wait doubles from one minute and stops at six hours`() {
        assertEquals(0L, MediaPostRetry.delayMs(0))
        assertEquals(60_000L, MediaPostRetry.delayMs(1))
        assertEquals(120_000L, MediaPostRetry.delayMs(2))
        assertEquals(240_000L, MediaPostRetry.delayMs(3))
        assertEquals(256 * 60_000L, MediaPostRetry.delayMs(9))
        assertEquals(MediaPostRetry.MAX_DELAY_MS, MediaPostRetry.delayMs(10))
        assertEquals(MediaPostRetry.MAX_DELAY_MS, MediaPostRetry.delayMs(500))
    }

    @Test fun `client errors are final except busy answers`() {
        for (code in listOf(400, 402, 403, 404, 413, 415)) assertTrue("$code", MediaPostRetry.isPermanentRefusal(code))
        for (code in listOf(401, 408, 429, 500, 502, 503, 200, -1)) assertFalse("$code", MediaPostRetry.isPermanentRefusal(code))
    }

    @Test fun `all refused needs a final answer from every mirror`() {
        val mirrors = listOf("https://a", "https://b")
        assertTrue(MediaPostRetry.allRefused(mirrors, mapOf("https://a" to 413, "https://b" to 402)))
        assertFalse("b never answered", MediaPostRetry.allRefused(mirrors, mapOf("https://a" to 413)))
        assertFalse("b was busy", MediaPostRetry.allRefused(mirrors, mapOf("https://a" to 413, "https://b" to 429)))
        assertFalse("b is down", MediaPostRetry.allRefused(mirrors, mapOf("https://a" to 413, "https://b" to 503)))
        assertFalse("no mirrors", MediaPostRetry.allRefused(emptyList(), emptyMap()))
    }

    @Test fun `a new post is due at once`() {
        val p = post()
        assertEquals(1_000L, p.nextAttemptAt)
        assertTrue(p.isDue(1_000L))
    }

    @Test fun `a failed post waits its turn`() {
        val p = post(attempts = 3, lastAttempt = 10_000L)
        assertEquals(10_000L + 240_000L, p.nextAttemptAt)
        assertFalse(p.isDue(10_000L + 239_999L))
        assertTrue(p.isDue(10_000L + 240_000L))
    }

    @Test fun `ten tries or a refusal stop it`() {
        assertFalse(post(attempts = 9, lastAttempt = 0).needsUser)
        val tired = post(attempts = 10, lastAttempt = 0)
        assertTrue(tired.needsUser)
        assertNull(tired.nextAttemptAt)
        assertFalse(tired.isDue(Long.MAX_VALUE))
        val refused = post(attempts = 1, lastAttempt = 0, refusedStatus = 413)
        assertTrue(refused.needsUser)
        assertFalse(refused.isDue(Long.MAX_VALUE))
    }

    @Test fun `sending again starts over`() {
        val again = post(attempts = 10, lastAttempt = 5_000L, refusedStatus = 402).resetForUserRetry()
        assertFalse(again.needsUser)
        assertTrue(again.isDue(5_000L))
    }

    @Test fun `big posts wait for wifi on a metered network`() {
        assertFalse(post(bytes = listOf(400_000L, 500_000L)).waitsForWifi(metered = true))
        assertTrue(post(bytes = listOf(600_000L, 500_000L)).waitsForWifi(metered = true))
        assertTrue("unknown size counts as big", post(bytes = listOf(null)).waitsForWifi(metered = true))
        assertFalse(post(bytes = listOf(50_000_000L)).waitsForWifi(metered = false))
    }

    @Test fun `only media still waiting counts toward the cellular limit`() {
        val p = post(bytes = listOf(5_000_000L, 200_000L)).let {
            it.copy(media = listOf(it.media[0].copy(url = "https://a/x"), it.media[1]))
        }
        assertFalse(p.waitsForWifi(metered = true))
    }

    @Test fun `stop reason says why`() {
        assertNull(WaitingPostStopReason.of(post(attempts = 2, lastAttempt = 0)))
        assertTrue(WaitingPostStopReason.of(post(refusedStatus = 413))!!.contains("HTTP 413"))
        assertTrue(WaitingPostStopReason.of(post(attempts = 10, lastAttempt = 0))!!.contains("10 tries"))
    }

    @Test fun `queue files from older builds still load`() {
        val old = """{"id":"x","createdAt":1,"accountNpub":"npub1a","body":"b","media":[],"baseTags":[],"attempts":4,"lastAttempt":9}"""
        val p = Json { ignoreUnknownKeys = true }.decodeFromString(QueuedMediaPost.serializer(), old)
        assertNull(p.refusedStatus)
        assertNotNull(p.nextAttemptAt)
    }
}
