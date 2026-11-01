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
    private val pending = mockk<PendingPostManager>(relaxed = true)
    private val nostr = mockk<NostrService>(relaxed = true)
    private val fresh = QueuedMediaPost.Media(sha256 = "a".repeat(64), mimeType = "image/jpeg", url = "https://m.example/${"a".repeat(64)}.jpg")

    @Before fun setUp() {
        Dispatchers.setMain(UnconfinedTestDispatcher())
        every { nostr.profiles } returns MutableStateFlow(emptyMap())
        every { nostr.serverLists } returns MutableStateFlow(emptyMap())
        coEvery { nostr.signEventAsync(any(), any(), any(), any(), any(), any(), any(), any()) } answers {
            NostrEvent("e".repeat(64), "f".repeat(64), 1_793_000_000, firstArg<Int>(), thirdArg(), secondArg(), "s")
        }
        every { pending.isSending(any()) } returns false
        every { pending.launchSend(any(), any()) } answers {
            val block = secondArg<suspend CoroutineScope.() -> Unit>()
            runBlocking { block() }
            mockk<Job>(relaxed = true)
        }
        coEvery { blossom.deleteFromServers(any(), any(), any()) } returns mockk(relaxed = true)
    }

    @After fun tearDown() = Dispatchers.resetMain()

    private fun viewModel(): ComposeNoteViewModel {
        val config = mockk<ConfigStore>(relaxed = true)
        every { config.config } returns MutableStateFlow(HavenConfig())
        every { config.activeAccountHexPubkey } returns MutableStateFlow("f".repeat(64))
        val drafts = mockk<DraftService>(relaxed = true)
        every { drafts.drafts } returns MutableStateFlow(emptyList<Draft>())
        val resolver = mockk<ContentResolver>(relaxed = true)
        every { resolver.getType(any()) } returns "image/jpeg"
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
            mediaPostQueue = mockk(relaxed = true),
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
            uploadSend = { _, _, _ -> ComposeNoteUpload.Done(fresh, preExisting = false) }
        }
    }

    /** Text typed, then a photo picked with the cursor at the end: its link is not placed, it goes at the end. */
    private fun ComposeNoteViewModel.withPhotoAtTheEnd(): ComposeNoteViewModel {
        onContentChanged("Blue skies", "Blue skies".length)
        addAttachments(listOf(mockk<Uri>(relaxed = true)), caret = "Blue skies".length)
        runBlocking { uploads.await(attachments.value) }
        return this
    }

    private fun ComposeNoteViewModel.close() {
        ViewModel::class.java.getDeclaredMethod("onCleared").apply { isAccessible = true }.invoke(this)
    }

    /** Positive control: closed without posting, the dropped upload comes off the servers. */
    @Test fun closingUnsentDeletesTheFreshUpload() {
        val vm = viewModel().withPhotoAtTheEnd()
        assertEquals(listOf(fresh.url), vm.closeCleanup()?.map { it.url })
        vm.close()
        coVerify(exactly = 1, timeout = 2_000) { blossom.deleteFromServers(fresh.sha256!!, null, false) }
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
}
