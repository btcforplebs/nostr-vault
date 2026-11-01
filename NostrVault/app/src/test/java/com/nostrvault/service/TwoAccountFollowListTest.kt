package com.nostrvault.service

import com.nostrvault.data.local.ConfigStore
import com.nostrvault.data.local.DeletedNotesStore
import com.nostrvault.data.model.PostingAccount
import com.nostrvault.relay.HavenBridge
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
import java.security.SecureRandom
import java.util.Collections

/**
 * Two accounts on one device, one of them imported. A follow or unfollow on
 * one account used to publish a list that also followed the other account
 * and itself: parsing added the owner and every device-wide whitelisted
 * npub. Keys are random throwaways made per run.
 */
@OptIn(ExperimentalCoroutinesApi::class)
class TwoAccountFollowListTest {
    @get:Rule val tmp = TemporaryFolder()

    private fun throwaway(): String {
        val bytes = ByteArray(32).also { SecureRandom().nextBytes(it) }
        return bytes.joinToString("") { "%02x".format(it) }
    }

    private val accountA = throwaway()
    private val importedB = throwaway()
    private val x = throwaway()
    private val y = throwaway()
    private val lockA = PostingAccount.Lock(npub = HavenBridge.encodeNpub(accountA)!!, hex = accountA)
    private lateinit var feed: FeedService
    private val signed = Collections.synchronizedList(mutableListOf<NostrEvent>())

    @Before
    fun setUp() {
        Dispatchers.setMain(StandardTestDispatcher())
        val deleted = DeletedNotesStore(tmp.root)
        mockkObject(DeletedNotesStore.Companion)
        every { DeletedNotesStore.shared } returns deleted
        val nostr = mockk<NostrService>(relaxed = true)
        every { nostr.activeHexPubkey } returns accountA
        every { nostr.lockPostingAccount() } returns lockA
        every { nostr.profiles } returns MutableStateFlow(emptyMap())
        // Account A has a relay list of its own and that relay answered: the list is known to be empty.
        coEvery { nostr.ownListRelays(accountA) } returns listOf("wss://own.example")
        coEvery { nostr.lookupNewestReplaceable(3, accountA, any(), any(), any()) } returns
            NostrService.ReplaceableLookup(null, asked = 1, answered = 1, answeredBy = setOf("wss://own.example"))
        val tags = slot<List<List<String>>>()
        coEvery { nostr.signEventAsync(3, any(), capture(tags), any(), any(), any(), any(), any()) } answers {
            NostrEvent(
                id = signed.size.toString().padStart(64, '0'), pubkey = accountA,
                createdAt = System.currentTimeMillis() / 1000, kind = 3,
                tags = tags.captured, content = "", sig = "",
            ).also { signed.add(it) }
        }
        val npubB = HavenBridge.encodeNpub(importedB)!!
        // What an older config carries: the imported account is both an
        // account and whitelisted (kept because the device holds its key).
        val config = HavenConfig(
            ownerNpub = lockA.npub,
            ownerHexKey = throwaway(), // a key is stored: not a read-only account
            accountNpubs = listOf(npubB),
            whitelistedNpubs = listOf(npubB),
        )
        val store = mockk<ConfigStore>(relaxed = true) {
            every { this@mockk.config } returns MutableStateFlow(config)
        }
        every { nostr.configStore } returns store
        feed = FeedService(
            appContext = mockk(relaxed = true),
            configStore = store,
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

    private fun publishedFollows(): List<String> =
        signed.last().tags.filter { it.firstOrNull() == "p" }.map { it[1] }

    @Test
    fun `a loaded list is exactly its p tags, without you or your other account`() {
        val parsed = ContactManager.parseContactList(listOf(listOf("p", x), listOf("t", "nostr")))
        assertEquals(listOf(x), parsed.pubkeys)
    }

    @Test
    fun `following on account A publishes only A's follows`() {
        feed.restoreContactList(listOf(listOf("p", x)), "")
        coVerify(timeout = 5_000) { feed.nostrService.postEvent(any(), any()) }
        assertEquals(listOf(x), publishedFollows())
        assertEquals(listOf(x), feed.followedPubkeys.value)

        feed._hasAttemptedContactLoad.value = true
        feed.contactListConfirmed = true
        Thread.sleep(1_100) // the next list needs a later created_at (C3)
        assertTrue(feed.followUser(y).isSuccess)
        coVerify(timeout = 5_000, exactly = 2) { feed.nostrService.postEvent(any(), any()) }
        assertEquals(listOf(x, y), publishedFollows())
    }

    @Test
    fun `unfollowing on account A never adds B or A`() {
        feed.restoreContactList(listOf(listOf("p", x), listOf("p", y)), "")
        coVerify(timeout = 5_000) { feed.nostrService.postEvent(any(), any()) }
        feed._hasAttemptedContactLoad.value = true
        feed.contactListConfirmed = true
        Thread.sleep(1_100)
        assertTrue(feed.unfollowUser(x).isSuccess)
        coVerify(timeout = 5_000, exactly = 2) { feed.nostrService.postEvent(any(), any()) }
        assertEquals(listOf(y), publishedFollows())
    }

    @Test
    fun `the Following feed still shows your own posts`() {
        feed._followedPubkeys.value = listOf(x)
        assertEquals(setOf(x, accountA), feed.feedAuthorSet())
        assertEquals(listOf(x, accountA), feed.feedAuthors())
        assertTrue(!feed.isFollowing(accountA))
    }

    @Test
    fun `a cached list from an older build drops the accounts it added`() {
        val cached = listOf(x, accountA, importedB)
        assertEquals(listOf(x), ContactManager.withoutAddedAccounts(cached, listOf(x), feed.deviceAccountHexes()))
        // Unless the relay copy really follows them.
        assertEquals(listOf(x, importedB), ContactManager.withoutAddedAccounts(cached, listOf(x, importedB), feed.deviceAccountHexes()))
    }
}
