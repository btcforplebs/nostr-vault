package com.nostrvault.service

import android.content.Context
import android.content.SharedPreferences
import com.nostrvault.ui.components.composeRouteFor
import io.mockk.every
import io.mockk.mockk
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.cancel
import kotlinx.coroutines.launch
import kotlinx.coroutines.test.StandardTestDispatcher
import kotlinx.coroutines.test.UnconfinedTestDispatcher
import kotlinx.coroutines.test.advanceTimeBy
import kotlinx.coroutines.test.advanceUntilIdle
import kotlinx.coroutines.test.resetMain
import kotlinx.coroutines.test.runCurrent
import kotlinx.coroutines.test.runTest
import kotlinx.coroutines.test.setMain
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test

/**
 * The post countdown: Cancel keeps the text and takes the early reply back
 * out of the thread, Edit hands the composer its draft, and a post that went
 * out is never taken back. iOS PendingPostManager.
 */
@OptIn(ExperimentalCoroutinesApi::class)
class PendingPostManagerTest {

    private val dispatcher = StandardTestDispatcher()

    @Before fun setUp() = Dispatchers.setMain(dispatcher)
    @After fun tearDown() = Dispatchers.resetMain()

    private fun manager(delaySeconds: Int = 5): PendingPostManager {
        val prefs = mockk<SharedPreferences>(relaxed = true)
        every { prefs.getInt(any(), any()) } returns delaySeconds
        val context = mockk<Context>()
        every { context.getSharedPreferences(any(), any()) } returns prefs
        return PendingPostManager(context)
    }

    private fun event(id: String) = NostrEvent(id, "pk", 0, 1, emptyList(), "hi", "sig")

    /** One post handed over; counts what ran. */
    private class Post {
        var published = 0
        var kept = 0
    }

    private fun PendingPostManager.post(id: String, draftId: String? = "draft-$id", replyToId: String? = null): Post {
        val post = Post()
        startPost(
            event = event(id),
            content = "text of $id",
            replyTo = null,
            quoteTo = null,
            draftId = draftId,
            replyToId = replyToId,
            onWithdrawn = { post.kept++ },
        ) { _, _ -> post.published++ }
        return post
    }

    @Test fun cancelKeepsTheDraftAndTakesTheReplyBack() = runTest(dispatcher) {
        val m = manager()
        val withdrawn = mutableListOf<String>()
        backgroundScope.launch(UnconfinedTestDispatcher(testScheduler)) { m.withdrawn.collect { withdrawn += it } }

        val post = m.post("e1", replyToId = "parent")
        advanceTimeBy(2_000)
        m.cancel()
        advanceUntilIdle()

        assertEquals(0, post.published)
        assertEquals(1, post.kept)
        assertEquals(listOf("e1"), withdrawn)
    }

    @Test fun editSavesTheDraftThenAsksForTheComposerOnIt() = runTest(dispatcher) {
        val m = manager()
        val order = mutableListOf<String>()
        var request: PendingPostManager.EditRequest? = null
        backgroundScope.launch(UnconfinedTestDispatcher(testScheduler)) {
            m.editRequest.collect { request = it; order += "edit" }
        }

        var published = 0
        m.startPost(
            event = event("e1"), content = "text", replyTo = null, quoteTo = null,
            draftId = "d1", replyToId = "parent",
            onWithdrawn = { order += "kept" },
        ) { _, _ -> published++ }
        advanceTimeBy(1_000)
        m.requestEdit()
        advanceUntilIdle()

        assertEquals(0, published)
        // The draft is written before the composer opens on it.
        assertEquals(listOf("kept", "edit"), order)
        val r = request!!
        assertEquals("d1", r.draftId)
        assertEquals("parent", r.replyToId)
        assertEquals("text", r.content)
        assertEquals("compose?replyTo=parent&draftId=d1", composeRouteFor(r))
    }

    @Test fun aPostThatWentOutIsNeverTakenBack() = runTest(dispatcher) {
        val m = manager()
        val withdrawn = mutableListOf<String>()
        backgroundScope.launch(UnconfinedTestDispatcher(testScheduler)) { m.withdrawn.collect { withdrawn += it } }

        val post = m.post("e1")
        advanceUntilIdle()
        m.cancel()
        m.requestEdit()
        advanceUntilIdle()

        assertEquals(1, post.published)
        assertEquals(0, post.kept)
        assertTrue(withdrawn.isEmpty())
        assertNull(m.actionType.value)
    }

    @Test fun withTheDelayOffThePostGoesStraightOut() = runTest(dispatcher) {
        val m = manager(delaySeconds = 0)
        val post = m.post("e1")
        advanceUntilIdle()
        assertEquals(1, post.published)
        assertEquals(0, post.kept)
    }

    @Test fun aNewPostReplacingAPendingOneKeepsItsDraft() = runTest(dispatcher) {
        val m = manager()
        val withdrawn = mutableListOf<String>()
        backgroundScope.launch(UnconfinedTestDispatcher(testScheduler)) { m.withdrawn.collect { withdrawn += it } }

        val first = m.post("e1")
        advanceTimeBy(1_000)
        val second = m.post("e2")
        advanceUntilIdle()

        assertEquals(0, first.published)
        assertEquals(1, first.kept)
        assertEquals(1, second.published)
        assertEquals(0, second.kept)
        assertEquals(listOf("e1"), withdrawn)
    }

    /** A send started from a composer outlives it: leaving mid-send must not cancel the post. */
    @Test fun aSendOutlivesTheScreenThatStartedIt() = runTest(dispatcher) {
        val m = manager()
        val screen = kotlinx.coroutines.CoroutineScope(kotlinx.coroutines.Job() + dispatcher)
        var sent = false
        screen.launch {
            m.launchSend("d1") {
                kotlinx.coroutines.delay(5_000) // the upload
                sent = true
            }
        }
        advanceTimeBy(1_000)
        screen.cancel() // the composer closes mid-upload
        advanceUntilIdle()
        assertTrue(sent)
    }

    /** Reopening a draft whose send is still running cannot start a second one: one note, not two. */
    @Test fun aDraftSendsOnceAtATime() = runTest(dispatcher) {
        val m = manager()
        var sends = 0
        val first = m.launchSend("d1") { kotlinx.coroutines.delay(5_000); sends++ }
        runCurrent()
        assertTrue(first != null && m.isSending("d1"))
        assertNull(m.launchSend("d1") { sends++ })
        // Another draft is not held up.
        assertTrue(m.launchSend("d2") { sends++ } != null)
        advanceUntilIdle()
        assertEquals(2, sends)
        assertTrue(!m.isSending("d1"))
        // Once it is done, the same draft may send again (e.g. after a failure).
        assertTrue(m.launchSend("d1") { sends++ } != null)
        advanceUntilIdle()
        assertEquals(3, sends)
    }

    /**
     * The undo countdown is still "on its way": the draft is on disk until
     * the post goes, so reopening and posting it then would send it twice.
     */
    @Test fun theUndoWindowStillCountsAsSending() = runTest(dispatcher) {
        val m = manager()
        val a = m.launchSend("draft-a") { m.post("a") }
        runCurrent()
        assertTrue(a!!.isCompleted)
        assertTrue("released before the countdown sent it", m.isSending("draft-a"))
        advanceTimeBy(6_000)
        runCurrent()
        assertTrue(!m.isSending("draft-a"))

        // Taken back with Cancel: free again at once, to edit and post.
        m.launchSend("draft-b") { m.post("b") }
        runCurrent()
        assertTrue(m.isSending("draft-b"))
        m.cancel()
        assertTrue(!m.isSending("draft-b"))

        // Replaced by a newer post: the older one is taken back and freed.
        m.launchSend("draft-c") { m.post("c") }
        runCurrent()
        m.launchSend("draft-d") { m.post("d") }
        runCurrent()
        assertTrue(!m.isSending("draft-c"))
        assertTrue(m.isSending("draft-d"))
    }

    /** With the send delay Off the post goes at once, and so does the hold. */
    @Test fun noCountdownNoHold() = runTest(dispatcher) {
        val m = manager(delaySeconds = 0)
        val post = Post()
        m.launchSend("draft-a") {
            m.startPost(event("a"), "text", null, null, draftId = "draft-a") { _, _ -> post.published++ }
        }
        advanceUntilIdle()
        assertEquals(1, post.published)
        assertTrue(!m.isSending("draft-a"))
    }
}
