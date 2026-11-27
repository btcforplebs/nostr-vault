package com.nostrvault.service

import android.content.Context
import com.nostrvault.data.local.ConfigStore
import com.nostrvault.data.local.DeletedNotesStore
import com.nostrvault.data.model.PostingAccount
import com.nostrvault.relay.HavenConfig
import io.mockk.coEvery
import io.mockk.coVerify
import io.mockk.every
import io.mockk.mockk
import io.mockk.mockkObject
import io.mockk.slot
import io.mockk.unmockkObject
import io.mockk.verify
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.test.UnconfinedTestDispatcher
import kotlinx.coroutines.test.resetMain
import kotlinx.coroutines.test.setMain
import org.junit.After
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder

/**
 * A new key's "no list yet" mark (kind 3 and 10015) is cleared only once a
 * relay accepts its first list, never at sign. Cleared at sign, a first
 * follow refused everywhere plus an app restart left the key marked as
 * having a list that is on no relay: every later follow then needed every
 * relay to answer, and one dead relay left a held new account unable to
 * follow anyone (Tron, 3.3.1 ship check §2). iOS twin: Tory, #nv-apple.
 */
@OptIn(ExperimentalCoroutinesApi::class)
class FreshKeyClearedOnAcceptTest {
    @get:Rule val tmp = TemporaryFolder()

    private val alice = "a".repeat(64)
    private val bob = "b".repeat(64)
    private val lockA = PostingAccount.Lock(npub = "npub1alice", hex = alice)
    private lateinit var nostr: NostrService
    private lateinit var context: Context
    private val outcome = slot<(BroadcastTally.Outcome) -> Unit>()

    @Before
    fun setUp() {
        Dispatchers.setMain(UnconfinedTestDispatcher())
        val deleted = DeletedNotesStore(tmp.root)
        mockkObject(DeletedNotesStore.Companion)
        every { DeletedNotesStore.shared } returns deleted
        mockkObject(FreshAccountKeys)
        context = mockk(relaxed = true)
        every { FreshAccountKeys.isFresh(any<Context>(), alice, any()) } returns true
        every { FreshAccountKeys.clear(any(), any(), any()) } returns Unit
        nostr = mockk(relaxed = true)
        every { nostr.outboxRelays } returns MutableStateFlow(emptyMap())
        every { nostr.activeHexPubkey } returns alice
        every { nostr.lockPostingAccount() } returns lockA
        coEvery { nostr.signEventAsync(any(), any(), any(), any(), any(), any(), any(), any()) } answers {
            NostrEvent(
                id = "0".repeat(64), pubkey = alice, createdAt = maxOf(System.currentTimeMillis() / 1000, arg<Long>(7)),
                kind = firstArg(), tags = arg(2), content = "", sig = "",
            )
        }
        // No relay answers the lookup: only a fresh key may sign at all.
        coEvery { nostr.lookupNewestReplaceable(3, alice, any(), any(), any()) } returns NostrService.ReplaceableLookup(null, asked = 2, answered = 0)
        every { nostr.postEvent(any(), capture(outcome)) } returns Unit
    }

    @After
    fun tearDown() {
        unmockkObject(FreshAccountKeys)
        unmockkObject(DeletedNotesStore.Companion)
        Dispatchers.resetMain()
    }

    private fun feed() = FeedService(
        appContext = context,
        // Main is unconfined, so the observers FeedService starts run now: a relaxed mock's flow throws when collected,
        // and the uncaught exception fails a later runTest test (ListMergeGapsTest).
        configStore = mockk<ConfigStore>(relaxed = true) {
            every { config } returns MutableStateFlow(HavenConfig())
            every { activeAccountHexPubkey } returns MutableStateFlow(alice)
            every { accountSwitches } returns kotlinx.coroutines.flow.emptyFlow()
        },
        nostrService = nostr,
        feedFilterEngine = mockk(relaxed = true),
        engagementTracker = mockk(relaxed = true),
        blobNoteIndexStore = mockk(relaxed = true),
        contactManager = ContactManager,
        imageLoader = mockk(relaxed = true),
        notificationManager = mockk(relaxed = true),
        followingBackupService = mockk(relaxed = true),
        lookupPool = mockk(relaxed = true),
        discoveryReach = mockk(relaxed = true) { every { admitted } returns com.nostrvault.data.model.DiscoveryReach.Admitted.NONE },
    )

    private fun interests() = InterestListService(
        context = context,
        configStore = mockk(relaxed = true) { every { activeAccountHexPubkey } returns MutableStateFlow(alice) },
        nostrService = nostr,
        lookupPool = mockk(relaxed = true),
    )

    private fun followOnce() {
        feed().publishContactList(listOf(bob), ContactManager.FollowEdit(add = listOf(bob)), rollback = emptyList())
        coVerify(timeout = 5_000) { nostr.postEvent(any(), any()) }
    }

    @Test
    fun `kind 3 stays fresh after signing until a relay answers`() {
        followOnce()
        Thread.sleep(200)
        verify(exactly = 0) { FreshAccountKeys.clear(any(), alice, 3) }
    }

    @Test
    fun `kind 3 refused everywhere stays fresh`() {
        followOnce()
        outcome.captured(BroadcastTally.Outcome.REFUSED)
        Thread.sleep(200)
        verify(exactly = 0) { FreshAccountKeys.clear(any(), alice, 3) }
    }

    @Test
    fun `kind 3 is cleared once a relay accepts`() {
        followOnce()
        outcome.captured(BroadcastTally.Outcome.ACCEPTED)
        verify(exactly = 1) { FreshAccountKeys.clear(any(), alice, 3) }
    }

    @Test
    fun `kind 10015 refused everywhere stays fresh, accepted clears it`() = runBlocking {
        val service = interests()
        assertTrue(service.setFollowing("art", followed = true))
        verify(exactly = 1) { nostr.postEvent(match { it.kind == InterestList.KIND }, any()) }
        verify(exactly = 0) { FreshAccountKeys.clear(any(), alice, InterestList.KIND) }
        outcome.captured(BroadcastTally.Outcome.REFUSED)
        verify(exactly = 0) { FreshAccountKeys.clear(any(), alice, InterestList.KIND) }
        outcome.captured(BroadcastTally.Outcome.ACCEPTED)
        verify(exactly = 1) { FreshAccountKeys.clear(any(), alice, InterestList.KIND) }
    }
}
