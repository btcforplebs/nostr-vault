package com.nostrvault.service

import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.test.StandardTestDispatcher
import kotlinx.coroutines.test.TestScope
import kotlinx.coroutines.test.advanceUntilIdle
import kotlinx.coroutines.test.runCurrent
import kotlinx.coroutines.test.runTest
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/** Own kind 5s from a resubscribe: known ids skip the signature check, the rest purge once. */
@OptIn(ExperimentalCoroutinesApi::class)
class DeleteRequestBatcherTest {

    private val dispatcher = StandardTestDispatcher()
    private val testScope = TestScope(dispatcher)

    private var activeAccount = "me"
    private val known = HashSet<String>()
    private val verified = ArrayList<String>()
    private val rejected = HashSet<String>()
    private val purges = ArrayList<Set<String>>()

    private val batcher = DeleteRequestBatcher(
        scope = testScope,
        verifyContext = dispatcher,
        purgeContext = dispatcher,
        account = { activeAccount },
        isKnown = { id, _ -> id in known },
        verify = { event, _ ->
            val id = (event["id"] as JsonPrimitive).content
            verified += id
            id !in rejected
        },
        purge = { ids -> purges += ids; known += ids },
    )

    private fun request(id: String) = JsonObject(mapOf("id" to JsonPrimitive(id)))

    @Test fun alreadyDeletedIdsSkipTheSignatureCheck() = testScope.runTest {
        known += setOf("a", "b")
        batcher.submit(request("k1"), setOf("a", "b"), "me")
        advanceUntilIdle()
        assertTrue(verified.isEmpty())
        assertTrue(purges.isEmpty())
    }

    @Test fun aBurstPurgesOnceWithEveryNewId() = testScope.runTest {
        known += "old"
        batcher.submit(request("k1"), setOf("a"), "me")
        batcher.submit(request("k2"), setOf("b", "old"), "me")
        batcher.submit(request("k3"), setOf("c"), "me")
        advanceUntilIdle()
        assertEquals(listOf("k1", "k2", "k3"), verified)
        assertEquals(listOf(setOf("a", "b", "c")), purges)
    }

    @Test fun aRequestThatFailsItsCheckPurgesNothing() = testScope.runTest {
        rejected += "forged"
        batcher.submit(request("forged"), setOf("x"), "me")
        batcher.submit(request("k1"), setOf("a"), "me")
        advanceUntilIdle()
        assertEquals(listOf(setOf("a")), purges)
    }

    @Test fun theSameRequestFromSeveralRelaysPurgesOnce() = testScope.runTest {
        repeat(3) { batcher.submit(request("k1"), setOf("a"), "me") }
        advanceUntilIdle()
        assertEquals(listOf(setOf("a")), purges)
        // A later resend is now a known id: no check, no purge.
        batcher.submit(request("k1"), setOf("a"), "me")
        advanceUntilIdle()
        assertEquals(3, verified.size)
        assertEquals(1, purges.size)
    }

    @Test fun aLaterBurstGetsItsOwnPurge() = testScope.runTest {
        batcher.submit(request("k1"), setOf("a"), "me")
        advanceUntilIdle()
        batcher.submit(request("k2"), setOf("b"), "me")
        advanceUntilIdle()
        assertEquals(listOf(setOf("a"), setOf("b")), purges)
    }

    @Test fun idsCheckedForAnAccountThatIsNoLongerActiveAreDropped() = testScope.runTest {
        batcher.submit(request("k1"), setOf("a"), "me")
        runCurrent()
        activeAccount = "other"
        advanceUntilIdle()
        assertTrue(purges.isEmpty())
    }

    @Test fun idsAppliedWhileTheBatchWaitedAreNotPurgedAgain() = testScope.runTest {
        batcher.submit(request("k1"), setOf("a", "b"), "me")
        runCurrent()
        known += "a"
        advanceUntilIdle()
        assertEquals(listOf(setOf("b")), purges)
    }
}
