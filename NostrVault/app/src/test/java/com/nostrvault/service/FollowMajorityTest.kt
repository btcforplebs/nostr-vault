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
 * The follow list's majority (Logen 2026-11-27, b6e725ef; web followListKnown and iOS the same): own relays that never
 * connected drop out of the count, at least 2 own relays must answer, a found list needs more than half of the ones that
 * connected, and "no list" needs all of them. rd had 3 of 7 own relays dead, so one slow relay refused every follow.
 * Runs the real [publishContactList]; Main is unconfined so the failure callback runs.
 */
@OptIn(ExperimentalCoroutinesApi::class)
class FollowMajorityTest {
    @get:Rule val tmp = TemporaryFolder()

    private val alice = "a".repeat(64)
    private val bob = "b".repeat(64)
    private val lockA = PostingAccount.Lock(npub = "npub1alice", hex = alice)
    private lateinit var nostr: NostrService
    private lateinit var feed: FeedService
    private val outcomes = ArrayBlockingQueue<String>(2)
    private val seven = (1..7).map { "wss://r$it" }
    @Volatile private var own: List<String> = seven
    @Volatile private var onRelays: NostrService.ReplaceableLookup = lookup(answered = seven, reached = seven)

    /** What the relays said: [answered] sent EOSE, [reached] connected (answered or not). */
    private fun lookup(answered: List<String>, reached: List<String>, found: Boolean = true, others: Set<String> = emptySet()) =
        NostrService.ReplaceableLookup(
            if (found) NostrEvent(id = "f".repeat(64), pubkey = alice, createdAt = 100, kind = 3, tags = listOf(listOf("p", bob)), content = "{}", sig = "") else null,
            asked = own.size + 2, answered = answered.size + others.size, answeredBy = answered.toSet() + others,
            from = answered.take(1).toSet(), reachedBy = reached.toSet() + others,
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
        every { nostr.postEvent(any(), any()) } answers {
            outcomes.add(PUBLISHED)
            secondArg<((BroadcastTally.Outcome) -> Unit)?>()?.invoke(BroadcastTally.Outcome.ACCEPTED)
        }
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

    /** PUBLISHED, or the pill a follow tap would show. */
    private fun follow(): String {
        feed._followedPubkeys.value = listOf(bob, alice)
        feed.publishContactList(listOf(bob, alice), ContactManager.FollowEdit(add = listOf(alice)), rollback = listOf(bob)) { why ->
            outcomes.add(followFailedMessage(true, why))
        }
        return outcomes.poll(5, TimeUnit.SECONDS) ?: error("neither published nor refused")
    }

    private fun short(answered: Int, of: Int) = "Couldn't follow: only $answered of your $of relays answered, so your newest " +
        "follow list can't be checked. Nothing changed. Remove dead relays in Settings › Relays, then try again."

    @Test fun `3 of 7 dead and the other 4 answer publishes`() {
        onRelays = lookup(answered = seven.take(4), reached = seven.take(4))
        assertEquals(PUBLISHED, follow())
    }

    @Test fun `3 of 7 dead and 3 of the other 4 answer publishes`() {
        // Old rule: 3 of 7 is not more than half, refused (rd 2026-11-27).
        onRelays = lookup(answered = seven.take(3), reached = seven.take(4))
        assertEquals(PUBLISHED, follow())
    }

    @Test fun `5 dead and both others answer publishes`() {
        onRelays = lookup(answered = seven.take(2), reached = seven.take(2))
        assertEquals(PUBLISHED, follow())
    }

    @Test fun `a slow relay that connected still counts against`() {
        // 4 connected, 2 answered: half is not more than half.
        onRelays = lookup(answered = seven.take(2), reached = seven.take(4))
        assertEquals(short(2, 7), follow())
    }

    @Test fun `1 answering is refused, even with only it connected and an indexer answering`() {
        onRelays = lookup(answered = seven.take(1), reached = seven.take(1), others = setOf("wss://purplepag.es"))
        assertEquals(
            "Couldn't follow: only 1 of your relays answered, and it takes 2 of them to check your newest follow list. " +
                "Nothing changed. Try again in a moment.",
            follow(),
        )
    }

    @Test fun `0 answering is refused`() {
        onRelays = lookup(answered = emptyList(), reached = seven.take(3))
        assertEquals(
            "Couldn't follow: none of your relays answered, so your newest follow list can't be checked. Nothing changed. " +
                "Check your connection, then try again.",
            follow(),
        )
    }

    @Test fun `a relay list of one relay can never be checked and says so`() {
        // Old rule: its one relay plus an indexer was enough.
        own = listOf("wss://r1")
        onRelays = lookup(answered = own, reached = own, others = setOf("wss://purplepag.es"))
        assertEquals(
            "Couldn't follow: your relay list has only one relay, and your newest follow list needs two of your relays " +
                "to answer before it can be checked. Nothing changed. Add a relay in Settings › Relays, then try again.",
            follow(),
        )
    }

    @Test fun `no list yet with a dead relay left out publishes the first one`() {
        // Old rule: "none" needed every relay asked to answer.
        own = seven.take(3)
        onRelays = lookup(answered = own.take(2), reached = own.take(2), found = false)
        assertEquals(PUBLISHED, follow())
    }

    @Test fun `no list yet needs every relay that connected`() {
        own = seven.take(3)
        onRelays = lookup(answered = own.take(2), reached = own, found = false)
        assertEquals(short(2, 3), follow())
    }

    @Test fun `no list yet with another relay connected but silent is refused`() {
        own = seven.take(2)
        onRelays = lookup(answered = own, reached = own, found = false).let { it.copy(reachedBy = it.reachedBy!! + "wss://inbox") }
        assertEquals(
            "Couldn't follow: not enough relays answered, so your newest follow list can't be checked. " +
                "Nothing changed. Try again in a moment.",
            follow(),
        )
    }

    private companion object { const val PUBLISHED = "published" }
}
