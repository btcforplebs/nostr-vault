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
    private fun follow(before: List<String> = listOf(bob)): String {
        feed._followedPubkeys.value = before + alice
        feed.publishContactList(before + alice, ContactManager.FollowEdit(add = listOf(alice)), rollback = before) { why ->
            outcomes.add(followFailedMessage(true, why))
        }
        return outcomes.poll(5, TimeUnit.SECONDS) ?: error("neither published nor refused")
    }

    private val notEnough = "Couldn't follow: not enough relays answered, so your newest follow list can't be checked. " +
        "Nothing changed. Try again in a moment."

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

    private val oneRelay = "Couldn't follow: your relay list has only one relay, and your newest follow list needs two of " +
        "your relays to answer before it can be checked. Nothing changed. Add a relay in Settings › Relays, then try again."

    @Test fun `a relay list of one relay plus purplepag es answering publishes`() {
        // Logen 2026-11-27 (b219c87b): with exactly one own write relay, the indexer is the second answer.
        own = listOf("wss://r1")
        onRelays = lookup(answered = own, reached = own, others = setOf("wss://purplepag.es"))
        assertEquals(PUBLISHED, follow())
    }

    @Test fun `a relay list of one relay asks purplepag es`() {
        own = listOf("wss://r1")
        onRelays = lookup(answered = own, reached = own, others = setOf("wss://purplepag.es"))
        follow()
        io.mockk.coVerify { nostr.lookupNewestReplaceable(3, alice, match { "wss://purplepag.es" in it && "wss://r1" in it }, any(), any()) }
    }

    @Test fun `a relay list of one relay with purplepag es silent is refused`() {
        own = listOf("wss://r1")
        onRelays = lookup(answered = own, reached = own)
        assertEquals(oneRelay, follow())
    }

    @Test fun `a relay list of one relay with purplepag es connected but silent is refused`() {
        own = listOf("wss://r1")
        onRelays = lookup(answered = own, reached = own).let { it.copy(reachedBy = it.reachedBy!! + "wss://purplepag.es") }
        assertEquals(oneRelay, follow())
    }

    @Test fun `a relay list of one relay that is silent is refused even with purplepag es answering`() {
        own = listOf("wss://r1")
        onRelays = lookup(answered = emptyList(), reached = own, others = setOf("wss://purplepag.es"))
        assertEquals(oneRelay, follow())
    }

    @Test fun `two own relays with one answering and purplepag es answering is still refused`() {
        own = seven.take(2)
        onRelays = lookup(answered = own.take(1), reached = own.take(1), others = setOf("wss://purplepag.es"))
        assertEquals(
            "Couldn't follow: only 1 of your relays answered, and it takes 2 of them to check your newest follow list. " +
                "Nothing changed. Try again in a moment.",
            follow(),
        )
    }

    @Test fun `a first list on a one-relay account needs purplepag es too`() {
        own = listOf("wss://r1")
        onRelays = lookup(answered = own, reached = own, found = false, others = setOf("wss://purplepag.es"))
        assertEquals(PUBLISHED, follow(before = emptyList()))
    }

    @Test fun `no list yet with a dead relay is refused`() {
        // A relay that didn't answer may hold the only copy; a first list sent to it would replace it (Tron, PR 2611).
        own = seven.take(3)
        onRelays = lookup(answered = own.take(2), reached = own.take(2), found = false)
        assertEquals(short(2, 3), follow(before = emptyList()))
    }

    @Test fun `no list yet with every own relay answering publishes the first one`() {
        own = seven.take(3)
        onRelays = lookup(answered = own, reached = own, found = false)
        assertEquals(PUBLISHED, follow(before = emptyList()))
    }

    @Test fun `no list found while the screen shows follows is refused, not a wipe`() {
        // Tron #2612: after a relaunch the snapshot shows 300 follows but no copy is held yet. 5 of 7 dead, the 2 that
        // connect say "none": signing would publish a list of 1 follow.
        val shown = (1..300).map { it.toString().padStart(64, 'c') }
        onRelays = lookup(answered = seven.take(2), reached = seven.take(2), found = false)
        // Refused on the count now (no list needs every own relay); the screen check is the next line of defence.
        assertEquals(short(2, 7), follow(before = shown))
    }

    @Test fun `no list found with a held copy builds on the copy`() {
        feed.knownContactList = ContactManager.ListCopy(alice, listOf(listOf("p", bob)), "{}", 100)
        onRelays = lookup(answered = seven.take(2), reached = seven.take(2), found = false)
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
        assertEquals(notEnough, follow(before = emptyList()))
    }

    private companion object { const val PUBLISHED = "published" }
}
