package com.nostrvault.ui.screens

import androidx.lifecycle.SavedStateHandle
import com.nostrvault.data.local.ConfigStore
import io.mockk.every
import io.mockk.mockk
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.test.StandardTestDispatcher
import kotlinx.coroutines.test.resetMain
import kotlinx.coroutines.test.setMain
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder
import java.io.File

/**
 * The composer's drafts belong to the account active when it opened, and
 * stay with it after a switch: one account never sees or writes over
 * another's.
 */
@OptIn(ExperimentalCoroutinesApi::class)
class ModeComposeDraftAccountTest {

    @get:Rule val tmp = TemporaryFolder()

    private val active = MutableStateFlow("alice")
    private lateinit var store: ComposerDraftStore

    @Before fun setUp() {
        Dispatchers.setMain(StandardTestDispatcher())
        store = ComposerDraftStore(File(tmp.root, "drafts"))
    }

    @After fun tearDown() = Dispatchers.resetMain()

    private fun viewModel(kind: String): ModeComposeViewModel {
        val config = mockk<ConfigStore>(relaxed = true)
        every { config.activeAccountHexPubkey } returns active
        return ModeComposeViewModel(
            nostrService = mockk(relaxed = true),
            blossomService = mockk(relaxed = true),
            reelsFeedService = mockk(relaxed = true),
            marketplaceFeedService = mockk(relaxed = true),
            notificationManager = mockk(relaxed = true),
            configStore = config,
            draftStore = store,
            context = mockk(relaxed = true),
            savedStateHandle = SavedStateHandle(mapOf("kind" to kind)),
        )
    }

    @Test fun draftsAreTheOpeningAccountsAndStayThereAfterASwitch() {
        store.save(ComposerDraft(ComposerDraft.Kind.ARTICLE, id = "b", title = "Bob's"), null, "bob")
        val drafts = viewModel("article").drafts!!
        assertEquals("alice", drafts.account)
        assertTrue("another account's draft is listed", drafts.others.value.isEmpty())

        active.value = "bob"
        drafts.saveNow(ComposerDraft(ComposerDraft.Kind.ARTICLE, title = "Alice's"), null)

        assertEquals(listOf("Alice's"), store.drafts(ComposerDraft.Kind.ARTICLE, "alice").map { it.title })
        assertEquals(listOf("Bob's"), store.drafts(ComposerDraft.Kind.ARTICLE, "bob").map { it.title })
    }

    @Test fun eachComposerKeepsItsOwnKind() {
        assertEquals(ComposerDraft.Kind.ARTICLE, viewModel("article").drafts!!.kind)
        assertEquals(ComposerDraft.Kind.RECIPE, viewModel("recipe").drafts!!.kind)
        assertEquals(ComposerDraft.Kind.POLL, viewModel("poll").drafts!!.kind)
        assertNull(viewModel("divine").drafts)
        assertNull(viewModel("listing").drafts)
    }
}
