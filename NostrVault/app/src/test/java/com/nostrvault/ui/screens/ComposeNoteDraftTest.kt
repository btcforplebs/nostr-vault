package com.nostrvault.ui.screens

import android.net.Uri
import com.nostrvault.data.model.QueuedMediaPost
import io.mockk.mockk
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

/** The composer's draft model: where a picked photo's link goes, and what the preview posts. */
class ComposeNoteDraftTest {
    private fun photo(id: String, hosted: String? = null) =
        Attachment(id = id, uri = mockk<Uri>(relaxed = true), mimeType = "image/jpeg", hostedUrl = hosted)

    private val me = "a".repeat(64)
    private fun done(url: String?, preExisting: Boolean = false, signer: String? = me) =
        ComposeNoteUpload.Done(QueuedMediaPost.Media(sha256 = "x", mimeType = "image/jpeg", url = url), preExisting = preExisting, signer = signer)

    @Test fun cursorInsideTheTextPlacesThePhoto() {
        assertEquals(5, ComposeNoteDraft.anchorFor("hello world", 5))
        assertEquals(0, ComposeNoteDraft.anchorFor("hello", 0))
    }

    /** At the end, or with no cursor at all, the photo is not placed and goes at the end as before. */
    @Test fun cursorAtTheEndOrNoneLeavesThePhotoUnplaced() {
        assertNull(ComposeNoteDraft.anchorFor("hello", 5))
        assertNull(ComposeNoteDraft.anchorFor("", 0))
        assertNull(ComposeNoteDraft.anchorFor("hello", null))
        assertNull(ComposeNoteDraft.anchorFor("hello", -1))
    }

    @Test fun typingBeforeTheSpotMovesItAlong() {
        assertEquals(5, ComposeNoteDraft.shift("abcd", "XYZabcd", 2))
    }

    @Test fun typingAfterTheSpotLeavesIt() {
        assertEquals(2, ComposeNoteDraft.shift("abcd", "abcdXYZ", 2))
        assertEquals(2, ComposeNoteDraft.shift("abcd", "abcXd", 2))
    }

    /** Typed right at the spot: the photo stays where the cursor was when it was picked. */
    @Test fun typingAtTheSpotGoesAfterThePhoto() {
        assertEquals(2, ComposeNoteDraft.shift("abcd", "abXYcd", 2))
    }

    @Test fun deletingAroundTheSpotPullsItToTheCut() {
        assertEquals(1, ComposeNoteDraft.shift("abcdef", "af", 3))
        assertEquals(0, ComposeNoteDraft.shift("abcdef", "", 3))
    }

    @Test fun linkGoesOnItsOwnLine() {
        assertEquals("Look\nhttps://x/1.jpg\nhere", ComposeNoteDraft.insertLink("Lookhere", 4, "https://x/1.jpg").first)
        assertEquals("Look\nhttps://x/1.jpg\nhere", ComposeNoteDraft.insertLink("Look\nhere", 5, "https://x/1.jpg").first)
        assertEquals("https://x/1.jpg\nhi", ComposeNoteDraft.insertLink("hi", 0, "https://x/1.jpg").first)
    }

    @Test fun insertReportsTheRunSoACursorCanMove() {
        val (_, at, length) = ComposeNoteDraft.insertLink("Lookhere", 4, "u")
        assertEquals(4, at)
        assertEquals(3, length) // "\nu\n"
    }

    @Test fun removingAPhotoTakesItsLineOut() {
        val placed = ComposeNoteDraft.insertLink("Lookhere", 4, "https://x/1.jpg").first
        assertEquals("Look\nhere", ComposeNoteDraft.removeLink(placed, "https://x/1.jpg"))
        assertEquals("unchanged", ComposeNoteDraft.removeLink("unchanged", "https://x/1.jpg"))
    }

    @Test fun linksNotInTheTextGoAtTheEnd() {
        assertEquals("hi\nhttps://a\nhttps://b", ComposeNoteDraft.withLinksAtEnd("hi", listOf("https://a", "https://b")))
        assertEquals("hi\nhttps://a\nthere\nhttps://b", ComposeNoteDraft.withLinksAtEnd("hi\nhttps://a\nthere", listOf("https://a", "https://b")))
    }

    /** The queue appends every link itself, as it always has, so placed ones come out of its body. */
    @Test fun queueBodyHasNoPlacedLinks() {
        assertEquals("hi\nthere", ComposeNoteDraft.withoutLinks("hi\nhttps://a\nthere", listOf("https://a")))
    }

    @Test fun previewShowsUploadedLinksAndLeavesOutRunningOnes() {
        val draft = ComposeNoteDraft(
            text = "Look\nhttps://x/1.jpg\nhere ",
            attachments = listOf(photo("1"), photo("2"), photo("3"), photo("4", hosted = "https://h/4.jpg")),
            uploads = mapOf("1" to done("https://x/1.jpg"), "2" to ComposeNoteUpload.Sending(0.5f), "3" to done(null)),
        )
        assertEquals("Look\nhttps://x/1.jpg\nhere\nhttps://h/4.jpg", draft.previewBody())
        assertEquals(1, draft.unfinished)
    }

    @Test fun failedCountsAsFinishedForTheWaitButNotAsALink() {
        val draft = ComposeNoteDraft(
            text = "x",
            attachments = listOf(photo("1")),
            uploads = mapOf("1" to ComposeNoteUpload.Failed("no")),
        )
        assertEquals(0, draft.unfinished)
        assertEquals("x", draft.previewBody())
    }

    @Test fun removingAPhotoTakesOutItsOwnLink() {
        val draft = ComposeNoteDraft(
            text = "a\nhttps://x/1.jpg\nb",
            attachments = listOf(photo("1"), photo("2")),
            uploads = mapOf("1" to done("https://x/1.jpg"), "2" to done("https://x/2.jpg")),
        )
        assertEquals("https://x/1.jpg", draft.linkToRemove("1"))
    }

    /** The same picture picked twice shares one link: removing one copy keeps it for the other. */
    @Test fun removingOneOfTwoCopiesKeepsTheSharedLink() {
        val draft = ComposeNoteDraft(
            text = "a\nhttps://x/1.jpg\nb",
            attachments = listOf(photo("1"), photo("2")),
            uploads = mapOf("1" to done("https://x/1.jpg"), "2" to done("https://x/1.jpg")),
        )
        assertNull(draft.linkToRemove("2"))
    }

    @Test fun relayPickedMediaAndUnfinishedUploadsHaveNoLinkToRemove() {
        val draft = ComposeNoteDraft(
            attachments = listOf(photo("1", hosted = "https://h/1.jpg"), photo("2")),
            uploads = mapOf("2" to ComposeNoteUpload.Sending(0.3f)),
        )
        assertNull(draft.linkToRemove("1"))
        assertNull(draft.linkToRemove("2"))
    }

    @Test fun removedFreshUploadIsDeleted() {
        val draft = ComposeNoteDraft(attachments = listOf(photo("1")), uploads = mapOf("1" to done("https://x/1.jpg")))
        assertEquals("https://x/1.jpg", draft.uploadToDelete("1", me)?.url)
    }

    /** Already in the vault before this pick (an earlier post may show it): never deleted. */
    @Test fun aBlobThatWasAlreadyThereIsNeverDeleted() {
        val draft = ComposeNoteDraft(attachments = listOf(photo("1")), uploads = mapOf("1" to done("https://x/1.jpg", preExisting = true)))
        assertNull(draft.uploadToDelete("1", me))
        assertEquals(emptyList<String>(), draft.unusedUploads("", me).map { it.url })
    }

    @Test fun aSharedBlobIsKeptForTheOtherCopy() {
        val draft = ComposeNoteDraft(
            attachments = listOf(photo("1"), photo("2")),
            uploads = mapOf("1" to done("https://x/1.jpg"), "2" to done("https://x/1.jpg")),
        )
        assertNull(draft.uploadToDelete("2", me))
    }

    /** Closing unsent: uploads whose link a kept draft holds stay; the rest come off the servers. */
    @Test fun closingDeletesOnlyWhatTheKeptTextDoesNotUse() {
        val draft = ComposeNoteDraft(
            attachments = listOf(photo("1"), photo("2"), photo("3")),
            uploads = mapOf("1" to done("https://x/1.jpg"), "2" to done("https://x/2.jpg"), "3" to done(null)),
        )
        assertEquals(listOf("https://x/2.jpg"), draft.unusedUploads("hi\nhttps://x/1.jpg", me).map { it.url })
        assertEquals(listOf("https://x/1.jpg", "https://x/2.jpg"), draft.unusedUploads("", me).map { it.url })
    }

    /** Only the account that uploaded a blob can sign its delete: none while another account is active. */
    @Test fun nothingIsDeletedWhileAnotherAccountIsActive() {
        val draft = ComposeNoteDraft(
            text = "",
            attachments = listOf(photo("1")),
            uploads = mapOf("1" to done("https://x/1.jpg", signer = "b".repeat(64))),
        )
        assertNull(draft.uploadToDelete("1", me))
        assertEquals(emptyList<String>(), draft.unusedUploads("", me).map { it.url })
        assertEquals("https://x/1.jpg", draft.uploadToDelete("1", "b".repeat(64))?.url)
    }

    @Test fun needsReuploadOnlyForAnotherSigner() {
        assertEquals(false, done("https://x/1.jpg").needsReupload(me))
        assertEquals(true, done("https://x/1.jpg", signer = "b".repeat(64)).needsReupload(me))
        assertEquals(true, done("https://x/1.jpg", signer = null).needsReupload(me))
        assertEquals(false, done(null, signer = "b".repeat(64)).needsReupload(me))
    }
}
