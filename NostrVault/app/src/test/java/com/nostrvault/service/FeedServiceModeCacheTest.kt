package com.nostrvault.service

import com.nostrvault.data.local.ConfigStore
import com.nostrvault.data.local.DeletedNotesStore
import com.nostrvault.data.model.FeedMode
import com.nostrvault.data.model.FeedNote
import com.nostrvault.relay.HavenConfig
import io.mockk.every
import io.mockk.mockk
import io.mockk.mockkObject
import io.mockk.unmockkObject
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.test.StandardTestDispatcher
import kotlinx.coroutines.test.resetMain
import kotlinx.coroutines.test.setMain
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Before
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder

/**
 * The mode cache through a real [FeedService]: [modeCacheKey],
 * [captureModeCache] and [restoreModeCache] keep each account's feeds apart.
 * Main is a test dispatcher that is never advanced, so the service's startup
 * collectors stay parked and only the cache code runs.
 */
@OptIn(ExperimentalCoroutinesApi::class)
class FeedServiceModeCacheTest {
    private fun note(id: String, at: Long) = FeedNote.fromEvent(id.padEnd(64, '0'), "a".repeat(64), id, emptyList(), at, 1)

    @get:Rule val tmp = TemporaryFolder()

    private var account = "alice"
    private lateinit var feed: FeedService

    @Before
    fun setUp() {
        Dispatchers.setMain(StandardTestDispatcher())
        // restoreModeCache drops deleted posts; none are deleted here. The
        // process-wide store is stubbed, never replaced, so no other test sees it.
        val deleted = DeletedNotesStore(tmp.root)
        mockkObject(DeletedNotesStore.Companion)
        every { DeletedNotesStore.shared } returns deleted
        val nostr = mockk<NostrService>(relaxed = true)
        every { nostr.activeHexPubkey } answers { account }
        feed = FeedService(
            appContext = mockk(relaxed = true),
            configStore = mockk<ConfigStore>(relaxed = true) {
                every { config } returns MutableStateFlow(HavenConfig())
            },
            nostrService = nostr,
            feedFilterEngine = mockk(relaxed = true),
            engagementTracker = mockk(relaxed = true),
            blobNoteIndexStore = mockk(relaxed = true),
            contactManager = mockk(relaxed = true),
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

    private fun showFeed(vararg notes: FeedNote) {
        feed._notes.value = notes.toList()
        feed._filteredNotes.value = notes.toList()
    }

    @Test
    fun `the key carries the active account`() {
        val alice = feed.modeCacheKey(FeedMode.FOLLOWING)
        account = "bob"
        assertEquals("bob|FOLLOWING", feed.modeCacheKey(FeedMode.FOLLOWING))
        assertEquals("alice|FOLLOWING", alice)
    }

    @Test
    fun `a feed captured under one account is not restored under another`() {
        showFeed(note("a1", 2), note("a2", 1))
        feed.captureModeCache(FeedMode.FOLLOWING)
        feed._notes.value = emptyList()

        account = "bob"
        assertNull(feed.restoreModeCache(FeedMode.FOLLOWING))
        assertEquals(emptyList<FeedNote>(), feed._notes.value)

        account = "alice"
        assertNotNull(feed.restoreModeCache(FeedMode.FOLLOWING))
        assertEquals(listOf("a1", "a2").map { it.padEnd(64, '0') }, feed._notes.value.map { it.id })
    }

    @Test
    fun `each account gets back its own feed`() {
        showFeed(note("a1", 1))
        feed.captureModeCache(FeedMode.GLOBAL)
        account = "bob"
        showFeed(note("b1", 1))
        feed.captureModeCache(FeedMode.GLOBAL)

        account = "alice"
        feed.restoreModeCache(FeedMode.GLOBAL)
        assertEquals(listOf("a1".padEnd(64, '0')), feed._notes.value.map { it.id })
        account = "bob"
        feed.restoreModeCache(FeedMode.GLOBAL)
        assertEquals(listOf("b1".padEnd(64, '0')), feed._notes.value.map { it.id })
    }

    @Test
    fun `an account switch reset drops the old account's feeds`() {
        showFeed(note("a1", 1))
        feed.captureModeCache(FeedMode.FOLLOWING)
        feed.clearInMemoryFeedState()
        assertNull(feed.restoreModeCache(FeedMode.FOLLOWING))
    }
}
