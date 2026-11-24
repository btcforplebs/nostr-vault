package com.nostrvault.service

import com.nostrvault.data.local.ConfigStore
import com.nostrvault.data.model.DiscoveryReach
import com.nostrvault.data.model.FeedMode
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
 * A moved reach bar or a re-read rank file sends Discover's request to the
 * local feed store again with the new distant list. It must not ask for the
 * owner's deletions again too: that replays every kind 5 for nothing.
 */
@OptIn(ExperimentalCoroutinesApi::class)
class DistantPostsResendTest {
    private val owner = "0".repeat(64)
    private val circle = "c".repeat(64)
    private val far = "d".repeat(64)
    private val config = MutableStateFlow(HavenConfig(ownerNpub = "npub1owner"))
    private val sent = mutableListOf<String>()
    private lateinit var feed: FeedService
    private lateinit var local: String

    @Before
    fun setUp() {
        Dispatchers.setMain(StandardTestDispatcher())
        local = config.value.localRelayURL("feed")!!
        feed = FeedService(
            appContext = mockk(relaxed = true),
            configStore = mockk<ConfigStore>(relaxed = true) { every { config } returns this@DistantPostsResendTest.config },
            nostrService = mockk(relaxed = true) { every { activeHexPubkey } returns owner },
            feedFilterEngine = FeedFilterEngine,
            engagementTracker = mockk(relaxed = true),
            blobNoteIndexStore = mockk(relaxed = true),
            contactManager = mockk(relaxed = true),
            imageLoader = mockk(relaxed = true),
            notificationManager = mockk(relaxed = true),
            followingBackupService = mockk(relaxed = true),
            lookupPool = mockk(relaxed = true),
            discoveryReach = mockk(relaxed = true) {
                every { admitted } returns DiscoveryReach.Admitted.NONE
                every { localDistantAuthors } returns listOf(far)
            },
        )
        feed.feedClients[local] = mockk<WebSocketClient>(relaxed = true) {
            every { connectionState } returns MutableStateFlow(WebSocketClient.ConnectionState.CONNECTED)
            every { send(any()) } answers { sent += firstArg<String>(); true }
        }
        feed._feedMode.value = FeedMode.DISCOVERY
        feed._extendedNetworkPubkeys.value = listOf(circle)
    }

    @After
    fun tearDown() = Dispatchers.resetMain()

    private fun subIds() = sent.map { Json.parseToJsonElement(it).jsonArray[1].jsonPrimitive.content }

    @Test
    fun resendCarriesTheDistantListButNotTheDeletions() {
        feed.resendDistantPostsRequest()
        val ids = subIds()
        assertEquals(listOf(feed.primaryFeedSubId()), ids)
        assertTrue(sent.single(), sent.single().contains(far))
    }

    @Test
    fun theFirstRequestStillAsksForTheDeletions() {
        feed.sendPrimaryFeedSubscription(local, feed.primaryFeedSubId())
        assertEquals(listOf(feed.primaryFeedSubId(), "del-${feed.primaryFeedSubId()}"), subIds())
    }
}
