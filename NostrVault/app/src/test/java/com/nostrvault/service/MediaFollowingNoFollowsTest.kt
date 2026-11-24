package com.nostrvault.service

import com.nostrvault.data.local.ConfigStore
import com.nostrvault.data.model.FeedMode
import com.nostrvault.data.model.FeedNote
import com.nostrvault.data.model.MediaFeedMode
import com.nostrvault.data.remote.WebSocketClient
import com.nostrvault.relay.HavenConfig
import io.mockk.every
import io.mockk.mockk
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.test.StandardTestDispatcher
import kotlinx.coroutines.test.resetMain
import kotlinx.coroutines.test.setMain
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonPrimitive
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test

/**
 * Media (Following) for an account that follows nobody asked the relays with
 * no `authors` (the filter builder drops an empty list), so the grid filled
 * with everyone's media. Following sends nothing for nobody; Media now too.
 */
@OptIn(ExperimentalCoroutinesApi::class)
class MediaFollowingNoFollowsTest {
    private val follow = "f".repeat(64)
    private val stranger = "5".repeat(64)
    private val config = MutableStateFlow(HavenConfig())
    private val sent = mutableListOf<String>()
    private lateinit var feed: FeedService

    @Before
    fun setUp() {
        Dispatchers.setMain(StandardTestDispatcher())
        feed = FeedService(
            appContext = mockk(relaxed = true),
            configStore = mockk<ConfigStore>(relaxed = true) { every { config } returns this@MediaFollowingNoFollowsTest.config },
            nostrService = mockk(relaxed = true),
            feedFilterEngine = FeedFilterEngine,
            engagementTracker = mockk(relaxed = true),
            blobNoteIndexStore = mockk(relaxed = true),
            contactManager = mockk(relaxed = true),
            imageLoader = mockk(relaxed = true),
            notificationManager = mockk(relaxed = true),
            followingBackupService = mockk(relaxed = true),
            lookupPool = mockk(relaxed = true),
            discoveryReach = mockk(relaxed = true) { every { admitted } returns com.nostrvault.data.model.DiscoveryReach.Admitted.NONE },
        )
        feed.feedClients["wss://relay.example"] = mockk<WebSocketClient>(relaxed = true) {
            every { send(any()) } answers { sent += firstArg<String>(); true }
        }
        feed._feedMode.value = FeedMode.MEDIA
        feed._mediaFeedMode.value = MediaFeedMode.FOLLOWING
    }

    @After
    fun tearDown() = Dispatchers.resetMain()

    private fun mediaReqs(): List<String> {
        feed.sendPrimaryFeedSubscription("wss://relay.example", "feed-media")
        return sent.filter { Json.parseToJsonElement(it).jsonArray[1].jsonPrimitive.content == "feed-media" }
    }

    private fun strangersPhoto() = FeedNote.fromEvent(
        "a".repeat(64), stranger, "look https://example.com/cat.jpg", emptyList(),
        System.currentTimeMillis() / 1000 - 60, 1,
    )

    @Test
    fun followingNobodyAsksTheRelaysForNothing() {
        feed._followedPubkeys.value = emptyList()
        assertEquals(emptyList<String>(), mediaReqs())
    }

    @Test
    fun followingSomeoneStillAsksForThem() {
        feed._followedPubkeys.value = listOf(follow)
        val req = mediaReqs().single()
        assertTrue(req, req.contains("\"authors\":[\"$follow\"]"))
    }

    @Test
    fun followingNobodyShowsNoMediaEvenWithGlobalsStillInTheList() {
        // Switched from Global: its notes outlive the scope change.
        feed._notes.value = listOf(strangersPhoto())
        feed._followedPubkeys.value = emptyList()
        feed.doRecomputeFilteredNotes()
        assertEquals(emptyList<FeedNote>(), feed.filteredMediaNotes.value)

        // Global still shows it (Everyone lifts the web), so the note is media.
        config.value = HavenConfig(globalShowsEveryone = true)
        feed._mediaFeedMode.value = MediaFeedMode.GLOBAL
        feed.doRecomputeFilteredNotes()
        assertEquals(1, feed.filteredMediaNotes.value.size)
    }
}
