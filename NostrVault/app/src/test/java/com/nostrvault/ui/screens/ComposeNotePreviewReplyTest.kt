package com.nostrvault.ui.screens

import android.content.Context
import androidx.lifecycle.SavedStateHandle
import com.nostrvault.data.local.ConfigStore
import com.nostrvault.data.model.Draft
import com.nostrvault.data.model.FeedNote
import com.nostrvault.relay.HavenConfig
import com.nostrvault.service.DraftService
import com.nostrvault.service.FeedService
import com.nostrvault.service.NostrService
import io.mockk.every
import io.mockk.mockk
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.test.UnconfinedTestDispatcher
import kotlinx.coroutines.test.resetMain
import kotlinx.coroutines.test.setMain
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test

/**
 * A reply previews as a reply (Tidy, RESEARCH/NV_COMPOSE_PREVIEW_DELAY_2026_11_27.md):
 * the preview note carries the same reply tags and kind the post signs
 * (buildReplyTags), so the card shows "reply to X" and the reply edge.
 */
@OptIn(ExperimentalCoroutinesApi::class)
class ComposeNotePreviewReplyTest {
    private val parentAuthor = "b".repeat(64)
    private val other = "c".repeat(64)

    @Before fun setUp() { Dispatchers.setMain(UnconfinedTestDispatcher()) }
    @After fun tearDown() { Dispatchers.resetMain() }

    private fun note(id: String, kind: Int, tags: List<List<String>> = emptyList()) = FeedNote.fromEvent(
        id = id, pubkey = parentAuthor, content = "the parent", tags = tags, createdAt = 1_793_000_000, kind = kind, verify = { true },
    )

    private fun viewModel(replyTo: String?, parent: FeedNote?): ComposeNoteViewModel {
        val nostr = mockk<NostrService>(relaxed = true)
        every { nostr.profiles } returns MutableStateFlow(emptyMap())
        every { nostr.serverLists } returns MutableStateFlow(emptyMap())
        val config = mockk<ConfigStore>(relaxed = true)
        every { config.config } returns MutableStateFlow(HavenConfig())
        every { config.activeAccountHexPubkey } returns MutableStateFlow("f".repeat(64))
        val drafts = mockk<DraftService>(relaxed = true)
        every { drafts.drafts } returns MutableStateFlow(emptyList<Draft>())
        val feed = mockk<FeedService>(relaxed = true)
        if (replyTo != null) every { feed.quoteTarget(replyTo) } returns parent
        return ComposeNoteViewModel(
            nostrService = nostr,
            feedService = feed,
            pendingPostManager = mockk(relaxed = true),
            draftService = drafts,
            blossomService = mockk(relaxed = true),
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
            context = mockk<Context>(relaxed = true),
            savedStateHandle = SavedStateHandle(if (replyTo != null) mapOf("replyTo" to replyTo) else emptyMap()),
        )
    }

    private fun ComposeNoteViewModel.preview(text: String): FeedNote {
        onContentChanged(text, text.length)
        return previewNote(draft.value)
    }

    @Test fun `a reply to a note previews as a kind 1 reply, with the post's own reply tags`() {
        val parentId = "a".repeat(64)
        val vm = viewModel(parentId, note(parentId, 1, listOf(listOf("p", other))))
        val preview = vm.preview("Agreed")
        assertEquals(1, preview.kind)
        assertTrue("reply to X shows", preview.isReply)
        assertEquals(parentId, preview.parentEventId)
        assertEquals(parentAuthor, preview.replyToPubkey)
        val (postTags, postKind) = vm.buildReplyTags()
        assertEquals(postKind, preview.kind)
        assertTrue("every reply tag the post signs is on the preview", preview.tags.containsAll(postTags))
        assertTrue(preview.tags.contains(listOf("p", other)))
    }

    @Test fun `a reply to a comment previews as a kind 1111 comment`() {
        val parentId = "d".repeat(64)
        val root = "e".repeat(64)
        val parent = note(parentId, 1111, listOf(listOf("E", root, "", parentAuthor), listOf("K", "1"), listOf("P", parentAuthor),
            listOf("e", root, "", parentAuthor), listOf("k", "1"), listOf("p", parentAuthor)))
        val vm = viewModel(parentId, parent)
        val preview = vm.preview("Me too")
        assertEquals(1111, preview.kind)
        assertEquals(vm.buildReplyTags(), vm.buildReplyTags().first to preview.kind)
        assertTrue(preview.tags.containsAll(vm.buildReplyTags().first))
    }

    @Test fun `a new note is not a reply`() {
        val preview = viewModel(null, null).preview("Hello")
        assertEquals(1, preview.kind)
        assertFalse(preview.isReply)
    }
}
