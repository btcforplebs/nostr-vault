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
import io.mockk.slot
import io.mockk.unmockkObject
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.test.StandardTestDispatcher
import kotlinx.coroutines.test.resetMain
import kotlinx.coroutines.test.setMain
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder
import java.util.Collections

/**
 * Publishing the follow list through a real [FeedService]: an account
 * switch forgets the old account's follows (C2), a list is signed only as
 * the account it belongs to (S3), keeps the loaded list's other tags (C1),
 * and two lists never share a created_at (C3). Main is a test dispatcher that
 * is never advanced; signing runs on the real IO dispatcher.
 */
@OptIn(ExperimentalCoroutinesApi::class)
class FeedServiceFollowListTest {
    @get:Rule val tmp = TemporaryFolder()

    private val alice = "a".repeat(64)
    private val bob = "b".repeat(64)
    private val lockA = PostingAccount.Lock(npub = "npub1alice", hex = alice)
    private lateinit var nostr: NostrService
    private lateinit var feed: FeedService
    private val signed = Collections.synchronizedList(mutableListOf<NostrEvent>())

    @Before
    fun setUp() {
        Dispatchers.setMain(StandardTestDispatcher())
        val deleted = DeletedNotesStore(tmp.root)
        mockkObject(DeletedNotesStore.Companion)
        every { DeletedNotesStore.shared } returns deleted
        nostr = mockk(relaxed = true)
        every { nostr.activeHexPubkey } returns alice
        every { nostr.lockPostingAccount() } returns lockA
        val tags = slot<List<List<String>>>()
        coEvery { nostr.signEventAsync(3, any(), capture(tags), any(), any(), any(), any()) } answers {
            NostrEvent(
                id = signed.size.toString().padStart(64, '0'), pubkey = alice,
                createdAt = System.currentTimeMillis() / 1000, kind = 3,
                tags = tags.captured, content = "", sig = "",
            ).also { signed.add(it) }
        }
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

    @Test
    fun `an account switch forgets the previous account's follows`() {
        feed._followedPubkeys.value = listOf(alice, bob)
        feed.contactListContent = "{\"wss://a\":{}}"
        feed.contactListTags = listOf(listOf("p", bob), listOf("t", "bitcoin"))
        feed.forgetFollowListForAccountSwitch()
        assertEquals(emptyList<String>(), feed._followedPubkeys.value)
        assertEquals("", feed.contactListContent)
        assertEquals(emptyList<List<String>>(), feed.contactListTags)
    }

    @Test
    fun `Reload Feed on the same account keeps the follow list`() {
        // Settings > Reload Feed runs forceReload, i.e. clearInMemoryFeedState.
        // A load that then finds no list but is confirmed must not leave an
        // empty set for the next follow tap to publish over the real one.
        feed._followedPubkeys.value = listOf(alice, bob)
        feed.contactListContent = "{\"wss://a\":{}}"
        feed.contactListTags = listOf(listOf("p", bob), listOf("t", "bitcoin"))
        feed.clearInMemoryFeedState()
        assertEquals(listOf(alice, bob), feed._followedPubkeys.value)
        assertEquals("{\"wss://a\":{}}", feed.contactListContent)
        assertEquals(listOf(listOf("p", bob), listOf("t", "bitcoin")), feed.contactListTags)
    }

    @Test
    fun `the list is signed locked to the account it belongs to`() {
        feed.publishContactList(listOf(alice, bob))
        coVerify(timeout = 5_000) { nostr.signEventAsync(3, any(), any(), any(), any(), lockA, any()) }
    }

    @Test
    fun `a switch during signing neither publishes nor rolls back`() {
        coEvery { nostr.signEventAsync(3, any(), any(), any(), any(), any(), any()) } throws PostingAccount.AccountChangedException()
        var failed = false
        feed._followedPubkeys.value = listOf(alice, bob)
        feed.publishContactList(listOf(alice, bob), rollback = listOf(alice)) { failed = true }
        coVerify(timeout = 5_000) { nostr.signEventAsync(3, any(), any(), any(), any(), any(), any()) }
        Thread.sleep(200)
        coVerify(exactly = 0) { nostr.postEvent(any(), any()) }
        assertEquals(listOf(alice, bob), feed._followedPubkeys.value)
        assertTrue(!failed)
    }

    @Test
    fun `a publish keeps the loaded list's other tags`() {
        feed.contactListTags = listOf(listOf("t", "bitcoin"), listOf("p", alice, "wss://r.example"), listOf("p", "bitcoin"))
        feed.publishContactList(listOf(alice, bob))
        coVerify(timeout = 5_000) { nostr.postEvent(any(), any()) }
        assertEquals(
            listOf(listOf("t", "bitcoin"), listOf("p", alice, "wss://r.example"), listOf("p", bob)),
            signed.single().tags,
        )
    }

    @Test
    fun `two publishes in one second get different created_at`() {
        feed.publishContactList(listOf(alice))
        feed.publishContactList(listOf(alice, bob))
        coVerify(timeout = 5_000, exactly = 2) { nostr.postEvent(any(), any()) }
        val times = signed.map { it.createdAt }
        assertTrue("created_at must increase, got $times", times[1] > times[0])
    }

    @Test
    fun `a new list makes Discovery count the follows' follows again`() {
        feed.lastExtendedNetworkLoadTime = System.currentTimeMillis()
        assertTrue(!feed.needsExtendedNetworkRefresh())
        feed.publishContactList(listOf(alice))
        assertTrue("an unfollow kept the old follows-of-follows tally", feed.needsExtendedNetworkRefresh())
    }
}
