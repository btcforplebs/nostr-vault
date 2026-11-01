package com.nostrvault.ui.screens

import android.content.ContentResolver
import android.content.Context
import android.net.Uri
import androidx.lifecycle.SavedStateHandle
import androidx.lifecycle.ViewModel
import com.nostrvault.data.local.ConfigStore
import com.nostrvault.data.model.Draft
import com.nostrvault.data.model.QueuedMediaPost
import com.nostrvault.relay.HavenConfig
import com.nostrvault.service.BlossomService
import com.nostrvault.service.DraftService
import com.nostrvault.service.NostrEvent
import com.nostrvault.service.NostrService
import com.nostrvault.service.PendingPostManager
import com.nostrvault.service.isReadOnlyAccount
import io.mockk.coEvery
import io.mockk.coVerify
import io.mockk.every
import io.mockk.mockk
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.Job
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.test.UnconfinedTestDispatcher
import kotlinx.coroutines.test.resetMain
import kotlinx.coroutines.test.setMain
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder

/**
 * Closing the composer deletes a dropped photo's fresh upload, and never one
 * a note was just posted with. Driven through the real ComposeNoteViewModel:
 * the data loss Tron found (#1511) was at the call site, after a successful
 * post, where a photo whose link went at the end looked unused.
 */
@OptIn(ExperimentalCoroutinesApi::class)
class ComposeNoteCloseCleanupTest {
    @get:Rule val tmp = TemporaryFolder()

    private val blossom = mockk<BlossomService>(relaxed = true)
    private val queue = mockk<com.nostrvault.service.MediaPostQueue>(relaxed = true)
    private val pending = mockk<PendingPostManager>(relaxed = true)
    private val nostr = mockk<NostrService>(relaxed = true)
    private val me = com.nostrvault.data.model.PostingAccount.Lock("npub1me", "f".repeat(64))
    private val fresh = QueuedMediaPost.Media(sha256 = "a".repeat(64), mimeType = "image/jpeg", url = "https://m.example/${"a".repeat(64)}.jpg")

    @Before fun setUp() {
        Dispatchers.setMain(UnconfinedTestDispatcher())
        io.mockk.mockkStatic("com.nostrvault.service.NostrServiceSigningKt")
        every { nostr.profiles } returns MutableStateFlow(emptyMap())
        every { nostr.serverLists } returns MutableStateFlow(emptyMap())
        coEvery { nostr.signEventAsync(any(), any(), any(), any(), any(), any(), any(), any()) } answers {
            NostrEvent("e".repeat(64), "f".repeat(64), 1_793_000_000, firstArg<Int>(), thirdArg(), secondArg(), "s")
        }
        every { pending.isSending(any()) } returns false
        every { nostr.lockPostingAccount() } returns me
        every { nostr.isReadOnlyAccount() } returns false
        every { pending.launchSend(any(), any()) } answers {
            val block = secondArg<suspend CoroutineScope.() -> Unit>()
            runBlocking { block() }
            mockk<Job>(relaxed = true)
        }
        coEvery { blossom.deleteFromServers(any(), any(), any()) } returns mockk(relaxed = true)
    }

    @After fun tearDown() {
        Dispatchers.resetMain()
        io.mockk.unmockkStatic("com.nostrvault.service.NostrServiceSigningKt")
    }

    private fun viewModel(): ComposeNoteViewModel {
        val config = mockk<ConfigStore>(relaxed = true)
        every { config.config } returns MutableStateFlow(HavenConfig())
        every { config.activeAccountHexPubkey } returns MutableStateFlow("f".repeat(64))
        val drafts = mockk<DraftService>(relaxed = true)
        every { drafts.drafts } returns MutableStateFlow(emptyList<Draft>())
        val resolver = mockk<ContentResolver>(relaxed = true)
        every { resolver.getType(any()) } returns "image/jpeg"
        // A file that ends: a mock stream never does, and an upload that got past a check would spin.
        every { resolver.openInputStream(any()) } answers { java.io.ByteArrayInputStream(byteArrayOf(1, 2, 3)) }
        val context = mockk<Context>(relaxed = true)
        every { context.contentResolver } returns resolver
        every { context.cacheDir } returns tmp.root
        return ComposeNoteViewModel(
            nostrService = nostr,
            feedService = mockk(relaxed = true),
            pendingPostManager = pending,
            draftService = drafts,
            blossomService = blossom,
            configStore = config,
            mediaPostQueue = queue,
            notificationManager = mockk(relaxed = true),
            blossomPickerMedia = mockk(relaxed = true),
            emojiPalette = mockk<com.nostrvault.data.local.EmojiPaletteStore>(relaxed = true).also {
                every { it.state } returns MutableStateFlow(com.nostrvault.data.local.EmojiPalette.State())
            },
            emojiList = mockk<com.nostrvault.service.EmojiListRepository>(relaxed = true).also {
                every { it.library } returns MutableStateFlow(com.nostrvault.service.EmojiListRepository.Library())
            },
            context = context,
            savedStateHandle = SavedStateHandle(),
        ).apply {
            // A fresh upload (the vault and every server had answered 404).
            uploadSend = { _, _, signAs, _ -> ComposeNoteUpload.Done(fresh, preExisting = false, signer = signAs.hex) }
        }
    }

    /** Text typed, then a photo picked with the cursor at the end: its link is not placed, it goes at the end. */
    private fun ComposeNoteViewModel.withPhotoAtTheEnd(): ComposeNoteViewModel {
        onContentChanged("Blue skies", "Blue skies".length)
        addAttachments(listOf(mockk<Uri>(relaxed = true)), caret = "Blue skies".length)
        runBlocking { uploads.await(attachments.value, me) }
        return this
    }

    private fun ComposeNoteViewModel.close() {
        ViewModel::class.java.getDeclaredMethod("onCleared").apply { isAccessible = true }.invoke(this)
    }

    /** Positive control: closed without posting, the dropped upload comes off the servers. */
    @Test fun closingUnsentDeletesTheFreshUpload() {
        val vm = viewModel().withPhotoAtTheEnd()
        assertEquals(listOf(fresh.url), vm.closeCleanup(me.hex)?.map { it.url })
        vm.close()
        // Signed by the account that uploaded it.
        coVerify(exactly = 1, timeout = 2_000) { blossom.deleteFromServers(fresh.sha256!!, null, false, me) }
    }

    /** The data loss Tron found: after a successful post, closing must delete nothing. */
    @Test fun closingAfterPostingDeletesNothing() {
        val vm = viewModel().withPhotoAtTheEnd()
        var published = false
        vm.publish { published = true }
        assertTrue("the post went out: ${vm.error.value}", published)
        vm.close()
        Thread.sleep(300)
        coVerify(exactly = 0) { blossom.deleteFromServers(any(), any(), any()) }
    }

    /** Post was tapped but the send failed: closing still deletes nothing (the photo may be in a draft or retried). */
    @Test fun closingAfterAFailedPostDeletesNothing() {
        coEvery { nostr.signEventAsync(any(), any(), any(), any(), any(), any(), any(), any()) } returns null
        val vm = viewModel().withPhotoAtTheEnd()
        vm.publish { }
        vm.close()
        Thread.sleep(300)
        coVerify(exactly = 0) { blossom.deleteFromServers(any(), any(), any()) }
    }

    /** A read-only account can sign nothing: Post says so plainly and signs nothing. */
    @Test fun aReadOnlyAccountIsToldItCannotPost() {
        val vm = viewModel()
        vm.onContentChanged("Blue skies", "Blue skies".length)
        every { nostr.isReadOnlyAccount() } returns true
        var published = false
        vm.publish { published = true }
        assertTrue(!published)
        assertEquals(ComposeNoteViewModel.READ_ONLY_ACCOUNT, vm.error.value)
        coVerify(exactly = 0) { nostr.signEventAsync(any(), any(), any(), any(), any(), any(), any(), any()) }
    }

    /** ... and its photo is not uploaded either. */
    @Test fun aReadOnlyAccountUploadsNothing() {
        val vm = viewModel()
        every { nostr.isReadOnlyAccount() } returns true
        val result = runBlocking { vm.uploadOne(Attachment(uri = mockk(relaxed = true), mimeType = "image/jpeg"), false, me) {} }
        assertEquals(ComposeNoteUpload.Failed(ComposeNoteViewModel.READ_ONLY_ACCOUNT), result)
        coVerify(exactly = 0) { blossom.uploadForPost(any(), any(), any(), any(), any(), any()) }
    }

    /**
     * Tron's must-fix on #1517, end to end: a photo picked as the owner lands
     * on the owner's server and its link is placed in the text; the user
     * switches to B and posts while the servers are down. B's queued note
     * must not carry the owner's link.
     */
    @Test fun aSwitchedAccountsQueuedNoteCarriesNoOtherAccountsLink() {
        val owner = com.nostrvault.data.model.PostingAccount.Lock("npub1owner", "0".repeat(64))
        var active = owner
        every { nostr.lockPostingAccount() } answers { active }
        val ownerUrl = "https://vault.owner.example/${"a".repeat(64)}"
        val vm = viewModel().apply {
            uploadSend = { _, _, signAs, _ ->
                if (signAs == owner) ComposeNoteUpload.Done(fresh.copy(url = ownerUrl), preExisting = false, signer = signAs.hex)
                else ComposeNoteUpload.Done(fresh.copy(url = null), unreachable = listOf("https://down"), preExisting = false, signer = signAs.hex)
            }
        }
        // Cursor inside the text: the owner's link is placed there.
        vm.onContentChanged("Look here", 4)
        vm.addAttachments(listOf(mockk<Uri>(relaxed = true)), caret = 4)
        runBlocking { vm.uploads.await(vm.attachments.value, owner) }
        assertTrue("placed: ${vm.content.value}", vm.content.value.contains(ownerUrl))

        active = me
        val queued = io.mockk.slot<QueuedMediaPost>()
        every { queue.enqueue(capture(queued)) } returns Unit
        vm.publish { }
        assertTrue("queued", queued.isCaptured)
        assertTrue("B's note body still has the owner's link: ${queued.captured.body}", !queued.captured.body.contains(ownerUrl))
        assertTrue(queued.captured.media.all { it.url == null })
    }

    /**
     * Tron's second case on #1517: the note is only the placed link. Taking it
     * out leaves the editor blank, and Post's fallback (the text it saved
     * before waiting) must not bring the owner's link back.
     */
    @Test fun aSwitchedAccountsLinkOnlyNoteCarriesNoOtherAccountsLink() {
        val owner = com.nostrvault.data.model.PostingAccount.Lock("npub1owner", "0".repeat(64))
        var active = owner
        every { nostr.lockPostingAccount() } answers { active }
        val ownerUrl = "https://vault.owner.example/${"a".repeat(64)}"
        val vm = viewModel().apply {
            uploadSend = { _, _, signAs, _ ->
                if (signAs == owner) ComposeNoteUpload.Done(fresh.copy(url = ownerUrl), preExisting = false, signer = signAs.hex)
                else ComposeNoteUpload.Done(fresh.copy(url = null), unreachable = listOf("https://down"), preExisting = false, signer = signAs.hex)
            }
        }
        vm.onContentChanged("Hi there", 2)
        vm.addAttachments(listOf(mockk<Uri>(relaxed = true)), caret = 2)
        runBlocking { vm.uploads.await(vm.attachments.value, owner) }
        assertTrue("placed: ${vm.content.value}", vm.content.value.contains(ownerUrl))
        // Both words deleted: the text is the owner's link alone.
        vm.onContentChanged(ownerUrl, ownerUrl.length)

        active = me
        val queued = io.mockk.slot<QueuedMediaPost>()
        every { queue.enqueue(capture(queued)) } returns Unit
        vm.publish { }
        assertTrue("queued", queued.isCaptured)
        assertTrue("B's note body still has the owner's link: ${queued.captured.body}", !queued.captured.body.contains(ownerUrl))
        assertTrue(queued.captured.media.all { it.url == null })
    }
}
