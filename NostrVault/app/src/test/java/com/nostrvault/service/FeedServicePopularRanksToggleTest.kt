package com.nostrvault.service

import com.nostrvault.data.local.ConfigStore
import com.nostrvault.data.local.DeletedNotesStore
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
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder

/**
 * The Ranks button's flag lives on the service, which is what the rank line
 * reads. Main is a test dispatcher that is never advanced.
 */
@OptIn(ExperimentalCoroutinesApi::class)
class FeedServicePopularRanksToggleTest {
    @get:Rule val tmp = TemporaryFolder()

    private val account = "alice"
    private lateinit var feed: FeedService

    @Before
    fun setUp() {
        Dispatchers.setMain(StandardTestDispatcher())
        // The process-wide deleted-notes store is stubbed, never replaced, so
        // no other test sees it.
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

    @Test
    fun `ranks are off until the button turns them on`() {
        assertFalse(feed.showPopularEngagement.value)
        feed.toggleShowPopularEngagement()
        assertTrue(feed.showPopularEngagement.value)
        feed.toggleShowPopularEngagement()
        assertFalse(feed.showPopularEngagement.value)
    }
}
