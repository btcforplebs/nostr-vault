package com.nostrvault.service

import com.nostrvault.relay.HavenConfig
import com.nostrvault.relay.blossomUploadServer
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.delay
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withTimeout
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/** A post needs one Blossom server to have the file; the others must never hold it. Port of iOS `PostOnFirstServerTests`. */
class PostOnFirstServerTest {
    /** Longer than the 2 s the post may take. */
    private val hang = 5_000L
    private val background = CoroutineScope(SupervisorJob() + Dispatchers.Default)

    @After fun tearDown() = background.cancel()

    @Test
    fun `a hanging server does not hold the post`() = runBlocking {
        val started = System.currentTimeMillis()
        val url = FirstAnswer.first(background, listOf(
            suspend { delay(hang); "hung" },
            suspend { delay(50); "https://blossom.nostr.build/x" },
        ))
        assertEquals("https://blossom.nostr.build/x", url)
        assertTrue("took ${System.currentTimeMillis() - started} ms", System.currentTimeMillis() - started < 2_000)
    }

    @Test
    fun `a failed server is passed over`() = runBlocking {
        val url = FirstAnswer.first(background, listOf(
            suspend { null },
            suspend { throw java.net.UnknownHostException("blossom.nostr.band") },
            suspend { delay(30); "third" },
        ))
        assertEquals("third", url)
    }

    @Test
    fun `every server failing is null`() = runBlocking {
        assertNull(FirstAnswer.first<String>(background, listOf(suspend { null }, suspend { null })))
        assertNull(FirstAnswer.first<String>(background, emptyList()))
    }

    @Test
    fun `the others finish in the background`() = runBlocking {
        val late = CompletableDeferred<Pair<Int, String?>>()
        val allDone = CompletableDeferred<Unit>()
        val url = FirstAnswer.first<String>(background, listOf(
            suspend { "fast" },
            suspend { delay(200); "slow" },
        ), onLate = { index, result -> late.complete(index to result) }, onAllDone = {
            assertTrue("all done before the slow server finished", late.isCompleted)
            allDone.complete(Unit)
        })
        assertEquals("fast", url)
        withTimeout(2_000) {
            assertEquals(1 to "slow", late.await())
            allDone.await()
        }
    }

    @Test
    fun `nostr build website addresses upload to its blossom server`() {
        for (typed in listOf("https://nostr.build", "https://nostr.build/", "https://logen.nostr.build", "https://image.nostr.build", " https://NOSTR.BUILD ")) {
            assertEquals(typed, "https://blossom.nostr.build", blossomUploadServer(typed))
        }
        assertEquals("https://blossom.nostr.build", blossomUploadServer("https://blossom.nostr.build"))
    }

    @Test
    fun `dead nostr band is skipped`() {
        assertNull(blossomUploadServer("https://blossom.nostr.band"))
        assertNull(blossomUploadServer("https://nostr.band"))
    }

    @Test
    fun `other servers are left alone`() {
        for (typed in listOf("https://blossom.primal.net", "https://npub1abc.blossom.band", "https://notnostr.build.example", "http://192.168.1.20:3355")) {
            assertEquals(typed, blossomUploadServer(typed))
        }
    }

    @Test
    fun `active mirrors map and deduplicate`() {
        val config = HavenConfig(blossomMirrors = listOf("https://logen.nostr.build", "https://blossom.nostr.band", "https://blossom.nostr.build", "https://blossom.primal.net"))
        assertEquals(listOf("https://blossom.nostr.build", "https://blossom.primal.net"), config.activeBlossomMirrors)
    }
}
