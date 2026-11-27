package com.nostrvault.service

import com.nostrvault.data.local.ConfigStore
import com.nostrvault.data.local.DeletedNotesStore
import com.nostrvault.data.model.PostingAccount
import com.nostrvault.relay.HavenConfig
import io.mockk.coEvery
import io.mockk.every
import io.mockk.mockk
import io.mockk.mockkObject
import io.mockk.unmockkObject
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.cancelAndJoin
import kotlinx.coroutines.job
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withTimeout
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.test.UnconfinedTestDispatcher
import kotlinx.coroutines.test.resetMain
import kotlinx.coroutines.test.setMain
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Before
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder
import java.util.concurrent.ArrayBlockingQueue
import java.util.concurrent.TimeUnit

/**
 * A follow that wasn't published says why on its pill, not a bare "Couldn't follow, try again" (rd 2026-11-27:
 * 3 of 7 own relays dead, every tap refused with no reason). Strings match iOS (Tory, nv-apple 2026-11-27 10:19Z).
 * Runs the real [publishContactList]; Main is unconfined so the failure callback runs.
 */
@OptIn(ExperimentalCoroutinesApi::class)
class FollowFailureReasonTest {
    @get:Rule val tmp = TemporaryFolder()

    private val alice = "a".repeat(64)
    private val bob = "b".repeat(64)
    private val lockA = PostingAccount.Lock(npub = "npub1alice", hex = alice)
    private lateinit var nostr: NostrService
    private lateinit var feed: FeedService
    @Volatile private var own: List<String> = listOf("wss://one", "wss://two", "wss://three")
    @Volatile private var onRelays: NostrService.ReplaceableLookup = copy(setOf("wss://one", "wss://two", "wss://three"))

    private fun copy(answeredBy: Set<String>) = NostrService.ReplaceableLookup(
        NostrEvent(id = "f".repeat(64), pubkey = alice, createdAt = 100, kind = 3, tags = listOf(listOf("p", bob)), content = "{}", sig = ""),
        asked = answeredBy.size, answered = answeredBy.size, answeredBy = answeredBy, from = setOf(answeredBy.first()),
    )

    @Before
    fun setUp() {
        Dispatchers.setMain(UnconfinedTestDispatcher())
        val deleted = DeletedNotesStore(tmp.root)
        mockkObject(DeletedNotesStore.Companion)
        every { DeletedNotesStore.shared } returns deleted
        nostr = mockk(relaxed = true)
        every { nostr.outboxRelays } returns MutableStateFlow(emptyMap())
        every { nostr.activeHexPubkey } returns alice
        every { nostr.lockPostingAccount() } returns lockA
        coEvery { nostr.signEventAsync(3, any(), any(), any(), any(), any(), any(), any()) } answers {
            NostrEvent(id = "0".repeat(64), pubkey = alice, createdAt = 200, kind = 3, tags = arg(2), content = "", sig = "")
        }
        coEvery { nostr.lookupNewestReplaceable(3, alice, any(), any(), any()) } answers { onRelays }
        coEvery { nostr.ownListRelays(alice) } answers { own }
        feed = FeedService(
            appContext = mockk(relaxed = true),
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
    }

    @After
    fun tearDown() {
        // The publish carries on after its pill (to Main, for the saved list): end it while Main is still set, or it
        // throws on the real Main and fails a later runTest test.
        runBlocking { withTimeout(5_000) { feed.scope.coroutineContext.job.cancelAndJoin() } }
        unmockkObject(DeletedNotesStore.Companion)
        Dispatchers.resetMain()
    }

    /** The pill a follow (or unfollow) tap would show for this publish. */
    private fun pill(follow: Boolean = true): String {
        val pills = ArrayBlockingQueue<String>(1)
        feed._followedPubkeys.value = listOf(bob, alice)
        feed.publishContactList(listOf(bob, alice), ContactManager.FollowEdit(add = listOf(alice)), rollback = listOf(bob)) { why ->
            pills.add(followFailedMessage(follow, why))
        }
        return pills.poll(5, TimeUnit.SECONDS) ?: error("no failure pill")
    }

    @Test fun `own relays below majority say how many answered`() {
        own = listOf("wss://one", "wss://two", "wss://three", "wss://four", "wss://five")
        onRelays = copy(setOf("wss://one", "wss://two", "wss://purplepag.es"))
        assertEquals(
            "Couldn't follow: only 2 of your 5 relays answered, so your newest follow list can't be checked. " +
                "Nothing changed. Remove dead relays in Settings › Relays, then try again.",
            pill(),
        )
    }

    @Test fun `one own relay answering says it takes two`() {
        onRelays = copy(setOf("wss://one", "wss://purplepag.es"))
        assertEquals(
            "Couldn't follow: only 1 relay answered, and it takes 2 to check your newest follow list. Nothing changed. " +
                "Try again in a moment.",
            pill(),
        )
    }

    @Test fun `no answer at all says no relay answered`() {
        coEvery { nostr.lookupNewestReplaceable(3, alice, any(), any(), any()) } throws RuntimeException("offline")
        assertEquals(
            "Couldn't unfollow: no relay answered, so your newest follow list can't be checked. Nothing changed. " +
                "Check your connection, then try again.",
            pill(follow = false),
        )
    }

    @Test fun `every own relay answered but too few in all`() {
        // Both own relays answered and none had a list, but another relay connected and stayed silent: it may hold it.
        own = listOf("wss://one", "wss://two")
        onRelays = NostrService.ReplaceableLookup(
            null, asked = 3, answered = 2, answeredBy = setOf("wss://one", "wss://two"),
            reachedBy = setOf("wss://one", "wss://two", "wss://inbox"),
        )
        assertEquals(
            "Couldn't follow: not enough relays answered, so your newest follow list can't be checked. " +
                "Nothing changed. Try again in a moment.",
            pill(),
        )
    }

    @Test fun `a signer that returns nothing is named`() {
        coEvery { nostr.signEventAsync(3, any(), any(), any(), any(), any(), any(), any()) } returns null
        assertEquals("Couldn't follow: your signer didn't sign it. Nothing changed. Check your signer, then try again.", pill())
    }

    @Test fun `every relay refusing is named`() {
        every { nostr.postEvent(any(), any()) } answers {
            secondArg<((BroadcastTally.Outcome) -> Unit)?>()?.invoke(BroadcastTally.Outcome.REFUSED)
        }
        assertEquals("Couldn't follow: every relay refused it. Nothing changed. Check your relays in Settings › Relays.", pill())
    }

    @Test fun `no relay list keeps its own wording`() {
        own = emptyList()
        assertEquals("Couldn't follow. ${ListMerge.NO_RELAY_LIST}", pill())
    }
}
