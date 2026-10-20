package com.nostrvault.service

import com.nostrvault.data.local.ConfigStore
import com.nostrvault.data.local.DeletedNotesStore
import com.nostrvault.data.model.PostingAccount
import com.nostrvault.relay.HavenConfig
import io.mockk.coEvery
import io.mockk.coVerify
import io.mockk.every
import io.mockk.mockk
import io.mockk.mockkObject
import io.mockk.unmockkObject
import io.mockk.verify
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.test.StandardTestDispatcher
import kotlinx.coroutines.test.resetMain
import kotlinx.coroutines.test.setMain
import org.junit.After
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder

/**
 * A repost is signed locked to the account it was handed off under, so a
 * switch while it signs (seconds with NIP-46 or Amber) refuses it instead of
 * reposting as the new account. Signing runs on the real IO dispatcher.
 */
@OptIn(ExperimentalCoroutinesApi::class)
class FeedServiceRepostLockTest {
    @get:Rule val tmp = TemporaryFolder()

    private val alice = "a".repeat(64)
    private val lockA = PostingAccount.Lock(npub = "npub1alice", hex = alice)
    private lateinit var nostr: NostrService
    private lateinit var feed: FeedService

    @Before
    fun setUp() {
        Dispatchers.setMain(StandardTestDispatcher())
        val deleted = DeletedNotesStore(tmp.root)
        mockkObject(DeletedNotesStore.Companion)
        every { DeletedNotesStore.shared } returns deleted
        nostr = mockk(relaxed = true)
        every { nostr.activeHexPubkey } returns alice
        every { nostr.lockPostingAccount() } returns lockA
        feed = FeedService(
            appContext = mockk(relaxed = true),
            configStore = mockk<ConfigStore>(relaxed = true) {
                every { config } returns MutableStateFlow(HavenConfig())
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
        )
    }

    @After
    fun tearDown() {
        unmockkObject(DeletedNotesStore.Companion)
        Dispatchers.resetMain()
    }

    private fun repost(pubkey: String) = NostrEvent("0".repeat(64), pubkey, 0, 6, emptyList(), "", "")

    @Test
    fun `the repost is signed locked to the account it was handed off under`() {
        coEvery { nostr.signEventAsync(6, any(), any(), any(), any(), any(), any()) } returns repost(alice)
        feed.repostNote("n1")
        coVerify(timeout = 5_000) { nostr.signEventAsync(6, any(), any(), any(), any(), lockA, any()) }
        verify(timeout = 5_000) { nostr.requireStillPostingAs(lockA, alice) }
        verify(timeout = 5_000) { nostr.postEvent(any(), any()) }
    }

    @Test
    fun `a switch while it signs publishes nothing and takes the repost back`() {
        coEvery { nostr.signEventAsync(6, any(), any(), any(), any(), any(), any()) } throws PostingAccount.AccountChangedException()
        feed.repostNote("n1")
        val deadline = System.currentTimeMillis() + 5_000
        while ("n1" in feed.repostedEventIds.value && System.currentTimeMillis() < deadline) Thread.sleep(10)
        assertTrue("n1" !in feed.repostedEventIds.value)
        verify(exactly = 0) { nostr.postEvent(any(), any()) }
    }
}
