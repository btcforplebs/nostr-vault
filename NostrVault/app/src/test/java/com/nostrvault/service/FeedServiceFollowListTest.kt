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
    private val carol = "c".repeat(64)
    private val signed = Collections.synchronizedList(mutableListOf<NostrEvent>())
    /** What the relays hold right before Save: null and answered 0 means none answered. */
    @Volatile private var onRelays: NostrService.ReplaceableLookup = NostrService.ReplaceableLookup(null, 2, 2, setOf("wss://one", "wss://two"))

    /** The account's own relays (its kind 10002); empty means it has no relay list. */
    @Volatile private var own: List<String> = listOf("wss://one", "wss://two")

    private fun relayCopy(at: Long, tags: List<List<String>>, sentBy: String = "wss://one") = NostrService.ReplaceableLookup(
        NostrEvent(id = "f".repeat(64), pubkey = alice, createdAt = at, kind = 3, tags = tags, content = "{}", sig = ""),
        asked = 2, answered = 1, answeredBy = setOf(sentBy), from = setOf(sentBy),
    )

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
        coEvery { nostr.signEventAsync(3, any(), capture(tags), any(), any(), any(), any(), any()) } answers {
            NostrEvent(
                id = signed.size.toString().padStart(64, '0'), pubkey = alice,
                // As the real signer: max(now, notBefore).
                createdAt = maxOf(System.currentTimeMillis() / 1000, arg<Long>(7)), kind = 3,
                tags = tags.captured, content = "", sig = "",
            ).also { signed.add(it) }
        }
        coEvery { nostr.lookupNewestReplaceable(3, alice, any(), any(), any()) } answers { onRelays }
        coEvery { nostr.ownListRelays(alice) } answers { own }
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
        feed.publishContactList(listOf(alice, bob), ContactManager.FollowEdit(add = listOf(alice, bob)))
        coVerify(timeout = 5_000) { nostr.signEventAsync(3, any(), any(), any(), any(), lockA, any(), any()) }
    }

    @Test
    fun `a switch during signing neither publishes nor rolls back`() {
        coEvery { nostr.signEventAsync(3, any(), any(), any(), any(), any(), any(), any()) } throws PostingAccount.AccountChangedException()
        var failed = false
        feed._followedPubkeys.value = listOf(alice, bob)
        feed.publishContactList(listOf(alice, bob), ContactManager.FollowEdit(add = listOf(bob)), rollback = listOf(alice)) { failed = true }
        coVerify(timeout = 5_000) { nostr.signEventAsync(3, any(), any(), any(), any(), any(), any(), any()) }
        Thread.sleep(200)
        coVerify(exactly = 0) { nostr.postEvent(any(), any()) }
        assertEquals(listOf(alice, bob), feed._followedPubkeys.value)
        assertTrue(!failed)
    }

    @Test
    fun `a publish keeps the newest list's other tags`() {
        onRelays = relayCopy(100, listOf(listOf("t", "bitcoin"), listOf("p", alice, "wss://r.example"), listOf("p", "bitcoin")))
        feed.publishContactList(listOf(alice, bob), ContactManager.FollowEdit(add = listOf(bob)))
        coVerify(timeout = 5_000) { nostr.postEvent(any(), any()) }
        assertEquals(
            listOf(listOf("t", "bitcoin"), listOf("p", alice, "wss://r.example"), listOf("p", bob)),
            signed.single().tags,
        )
    }

    @Test
    fun `a contact list loaded a day ahead does not date later follows ahead`() {
        val now = System.currentTimeMillis() / 1000
        // Another app with a bad clock: the service saw a kind 3 dated a day ahead.
        feed.lastContactListCreatedAt.set(now + 86_400)
        onRelays = relayCopy(now - 60, listOf(listOf("p", bob)))
        feed.publishContactList(listOf(bob, alice), ContactManager.FollowEdit(add = listOf(alice)), rollback = listOf(bob))
        coVerify(timeout = 5_000) { nostr.postEvent(any(), any()) }
        val at = signed.single().createdAt
        assertTrue("signed at $at, now $now", at < now + ListMerge.MAX_SKEW)
    }

    @Test
    fun `two publishes in one second get different created_at`() {
        feed.publishContactList(listOf(alice), ContactManager.FollowEdit(add = listOf(alice)))
        feed.publishContactList(listOf(alice, bob), ContactManager.FollowEdit(add = listOf(bob)))
        coVerify(timeout = 5_000, exactly = 2) { nostr.postEvent(any(), any()) }
        val times = signed.map { it.createdAt }
        assertTrue("created_at must increase, got $times", times[1] > times[0])
        // The second edit went onto the first one's signed copy, not the empty one fetched.
        assertEquals(listOf(listOf("p", alice), listOf("p", bob)), signed[1].tags)
    }

    @Test
    fun `a follow tap edits the newest copy, not the one read at launch`() {
        // Launch read bob; since then another app followed carol.
        feed._followedPubkeys.value = listOf(bob)
        feed.contactListTags = listOf(listOf("p", bob))
        onRelays = relayCopy(200, listOf(listOf("p", bob), listOf("p", carol)))
        feed.publishContactList(listOf(bob, alice), ContactManager.FollowEdit(add = listOf(alice)), rollback = listOf(bob))
        coVerify(timeout = 5_000) { nostr.postEvent(any(), any()) }
        assertEquals(listOf(listOf("p", bob), listOf("p", carol), listOf("p", alice)), signed.single().tags)
        assertTrue("signed in a later second than the copy it edits", signed.single().createdAt > 200)
    }

    @Test
    fun `no list signed when only some relays answer none`() {
        onRelays = NostrService.ReplaceableLookup(null, asked = 3, answered = 1)
        feed.publishContactList(listOf(alice), ContactManager.FollowEdit(add = listOf(alice)), rollback = emptyList())
        coVerify(timeout = 5_000) { nostr.lookupNewestReplaceable(3, alice, any(), any(), any()) }
        Thread.sleep(300)
        coVerify(exactly = 0) { nostr.signEventAsync(3, any(), any(), any(), any(), any(), any(), any()) }
        assertEquals(0, feed.contactEditsInFlight.get())
    }

    @Test
    fun `no list signed over a copy from the app's defaults when the account has no relay list`() {
        own = emptyList()
        onRelays = relayCopy(200, listOf(listOf("p", bob)), sentBy = "wss://relay.damus.io")
        feed.publishContactList(listOf(alice), ContactManager.FollowEdit(add = listOf(alice)), rollback = emptyList())
        coVerify(timeout = 5_000) { nostr.lookupNewestReplaceable(3, alice, any(), any(), any()) }
        Thread.sleep(300)
        coVerify(exactly = 0) { nostr.signEventAsync(3, any(), any(), any(), any(), any(), any(), any()) }
        assertEquals(0, feed.contactEditsInFlight.get())
    }

    @Test
    fun `the own relays are asked for the follow list too`() {
        own = listOf("wss://own-only.example")
        onRelays = relayCopy(200, listOf(listOf("p", bob)), sentBy = "wss://own-only.example")
        feed.publishContactList(listOf(bob, alice), ContactManager.FollowEdit(add = listOf(alice)))
        coVerify(timeout = 5_000) { nostr.lookupNewestReplaceable(3, alice, match { "wss://own-only.example" in it }, any(), any()) }
        coVerify(timeout = 5_000) { nostr.signEventAsync(3, any(), any(), any(), any(), any(), any(), any()) }
    }

    @Test
    fun `a follow already on the newest copy signs nothing`() {
        onRelays = relayCopy(200, listOf(listOf("p", alice)))
        feed.publishContactList(listOf(alice), ContactManager.FollowEdit(add = listOf(alice)))
        coVerify(timeout = 5_000) { nostr.lookupNewestReplaceable(3, alice, any(), any(), any()) }
        Thread.sleep(300)
        coVerify(exactly = 0) { nostr.signEventAsync(3, any(), any(), any(), any(), any(), any(), any()) }
    }

    @Test
    fun `a new list makes Discovery count the follows' follows again`() {
        feed.lastExtendedNetworkLoadTime = System.currentTimeMillis()
        assertTrue(!feed.needsExtendedNetworkRefresh())
        feed.publishContactList(listOf(alice), ContactManager.FollowEdit(add = listOf(alice)))
        assertTrue("an unfollow kept the old follows-of-follows tally", feed.needsExtendedNetworkRefresh())
    }
}
