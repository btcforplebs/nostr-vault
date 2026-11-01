package com.nostrvault.ui.screens

import android.net.Uri
import com.nostrvault.data.model.MediaUploadOutcomeMessage
import com.nostrvault.data.model.QueuedMediaPost
import io.mockk.mockk
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.async
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.test.advanceUntilIdle
import kotlinx.coroutines.test.runTest
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/** Uploads start on pick, run one at a time in order, cancel on remove, and Post waits on them. */
@OptIn(ExperimentalCoroutinesApi::class)
class ComposeNoteUploadsTest {
    private fun photo(id: String, hosted: String? = null) =
        Attachment(id = id, uri = mockk<Uri>(relaxed = true), mimeType = "image/jpeg", hostedUrl = hosted)

    private fun media(id: String, url: String? = "https://x/$id.jpg") =
        QueuedMediaPost.Media(sha256 = id, mimeType = "image/jpeg", url = url)

    private val hosted: (Attachment) -> QueuedMediaPost.Media = { QueuedMediaPost.Media(sha256 = it.sha256, mimeType = null, url = it.hostedUrl) }

    @Test fun uploadsOneAtATimeInPickedOrder() = runTest {
        val log = mutableListOf<String>()
        val gates = mapOf("1" to CompletableDeferred<Unit>(), "2" to CompletableDeferred())
        val uploads = ComposeNoteUploads(this, { a, _, _ ->
            log += "start ${a.id}"
            gates.getValue(a.id).await()
            log += "end ${a.id}"
            ComposeNoteUpload.Done(media(a.id))
        }, hosted)
        uploads.start(photo("1"))
        uploads.start(photo("2"))
        advanceUntilIdle()
        assertEquals(listOf("start 1"), log)
        assertTrue(uploads.states.value["2"] is ComposeNoteUpload.Waiting)
        gates.getValue("1").complete(Unit)
        advanceUntilIdle()
        assertEquals(listOf("start 1", "end 1", "start 2"), log)
        gates.getValue("2").complete(Unit)
        advanceUntilIdle()
        assertTrue(uploads.states.value["2"] is ComposeNoteUpload.Done)
    }

    /** A pick never skips the outside servers: one offline pick must not make later picks device-only. */
    @Test fun picksNeverSkipTheOutsideServers() = runTest {
        val skipped = mutableListOf<Boolean>()
        val uploads = ComposeNoteUploads(this, { a, skip, _ ->
            skipped += skip
            ComposeNoteUpload.Done(media(a.id, url = null), unreachable = listOf("https://down"))
        }, hosted)
        uploads.start(photo("1"))
        uploads.start(photo("2"))
        advanceUntilIdle()
        assertEquals(listOf(false, false), skipped)
    }

    /**
     * At Post, what is only on this device is tried again, and as the old
     * loop did, once one try finds every server down the rest of that Post
     * skips them. The next Post starts fresh.
     */
    @Test fun postRetriesDeviceOnlyUploadsWithTheServersDownRulePerPost() = runTest {
        val calls = mutableListOf<Pair<String, Boolean>>()
        var online = false
        val uploads = ComposeNoteUploads(this, { a, skip, _ ->
            calls += a.id to skip
            if (online && !skip) ComposeNoteUpload.Done(media(a.id))
            else ComposeNoteUpload.Done(media(a.id, url = null), unreachable = listOf("https://down"))
        }, hosted)
        val photos = listOf(photo("1"), photo("2"))
        photos.forEach { uploads.start(it) }
        advanceUntilIdle()
        calls.clear()
        val first = uploads.await(photos) as ComposeNoteViewModel.AttachmentUploadResult.Done
        assertEquals(listOf("1" to false, "2" to true), calls)
        assertEquals(listOf("https://down"), first.unreachableServers)
        calls.clear()
        online = true
        val second = uploads.await(photos) as ComposeNoteViewModel.AttachmentUploadResult.Done
        assertEquals(listOf("1" to false, "2" to false), calls)
        assertEquals(listOf("https://x/1.jpg", "https://x/2.jpg"), second.media.map { it.url })
        assertTrue(second.unreachableServers.isEmpty())
    }

    @Test fun removingAPhotoCancelsItsUpload() = runTest {
        val gate = CompletableDeferred<Unit>()
        var landed: String? = null
        val uploads = ComposeNoteUploads(this, { a, _, _ -> gate.await(); ComposeNoteUpload.Done(media(a.id)) }, hosted)
        uploads.onDone = { a, _ -> landed = a.id }
        uploads.start(photo("1"))
        advanceUntilIdle()
        uploads.cancel("1")
        gate.complete(Unit)
        advanceUntilIdle()
        assertEquals(null, landed)
        assertTrue("1" !in uploads.states.value)
    }

    @Test fun postWaitsForUnfinishedUploadsAndKeepsOrder() = runTest {
        val gate = CompletableDeferred<Unit>()
        val uploads = ComposeNoteUploads(this, { a, _, _ ->
            if (a.id == "2") gate.await()
            ComposeNoteUpload.Done(media(a.id))
        }, hosted)
        val photos = listOf(photo("1"), photo("2"), photo("3", hosted = "https://h/3.jpg"))
        photos.forEach { uploads.start(it) }
        val result = async { uploads.await(photos) }
        advanceUntilIdle()
        assertTrue(!result.isCompleted)
        gate.complete(Unit)
        advanceUntilIdle()
        val done = result.await() as ComposeNoteViewModel.AttachmentUploadResult.Done
        assertEquals(listOf("https://x/1.jpg", "https://x/2.jpg", "https://h/3.jpg"), done.media.map { it.url })
    }

    /** A failed upload is tried once more at Post, as it would have been when Post did all the uploading. */
    @Test fun postRetriesAFailedUploadOnce() = runTest {
        var tries = 0
        val uploads = ComposeNoteUploads(this, { a, _, _ ->
            tries++
            if (tries == 1) ComposeNoteUpload.Failed(MediaUploadOutcomeMessage.NOT_SAVED_ON_DEVICE) else ComposeNoteUpload.Done(media(a.id))
        }, hosted)
        uploads.start(photo("1"))
        advanceUntilIdle()
        assertTrue(uploads.states.value["1"] is ComposeNoteUpload.Failed)
        val result = uploads.await(listOf(photo("1")))
        assertTrue(result is ComposeNoteViewModel.AttachmentUploadResult.Done)
        assertEquals(2, tries)
    }

    @Test fun aSecondFailureStopsThePostWithItsMessage() = runTest {
        val uploads = ComposeNoteUploads(this, { _, _, _ -> ComposeNoteUpload.Failed("nope") }, hosted)
        uploads.start(photo("1"))
        advanceUntilIdle()
        assertEquals(ComposeNoteViewModel.AttachmentUploadResult.Failed("nope"), uploads.await(listOf(photo("1"))))
    }

    /** ALT text written after the upload finished still reaches the post. */
    @Test fun altWrittenLaterIsUsed() = runTest {
        val uploads = ComposeNoteUploads(this, { a, _, _ -> ComposeNoteUpload.Done(media(a.id)) }, hosted)
        uploads.start(photo("1"))
        advanceUntilIdle()
        val done = uploads.await(listOf(photo("1").copy(altText = "a dog"))) as ComposeNoteViewModel.AttachmentUploadResult.Done
        assertEquals("a dog", done.media.single().alt)
    }

    @Test fun progressShowsWhileSending() = runTest {
        val gate = CompletableDeferred<Unit>()
        val uploads = ComposeNoteUploads(this, { a, _, progress -> progress(0.4f); gate.await(); ComposeNoteUpload.Done(media(a.id)) }, hosted)
        uploads.start(photo("1"))
        advanceUntilIdle()
        assertEquals(ComposeNoteUpload.Sending(0.4f), uploads.states.value["1"])
        gate.complete(Unit)
        advanceUntilIdle()
    }
}
