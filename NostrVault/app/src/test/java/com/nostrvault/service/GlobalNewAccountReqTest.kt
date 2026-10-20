package com.nostrvault.service

import com.nostrvault.data.local.ConfigStore
import com.nostrvault.data.model.FeedMode
import com.nostrvault.data.model.FeedNote
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
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonPrimitive
import kotlinx.serialization.json.long
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Before
import org.junit.Test

/**
 * A new account's Global was blank: its REQ was the open firehose and the
 * client then dropped everyone outside a web of one or two people, who
 * almost never appear in a page of 500 strangers (iOS #824). Global now names
 * the trusted authors in a filter of their own.
 */
@OptIn(ExperimentalCoroutinesApi::class)
class GlobalNewAccountReqTest {
    private val follow = "f".repeat(64)
    private val owner = "0".repeat(64)
    private val stranger = "5".repeat(64)
    private val config = MutableStateFlow(HavenConfig())
    private val sent = mutableListOf<String>()
    private lateinit var feed: FeedService

    @Before
    fun setUp() {
        Dispatchers.setMain(StandardTestDispatcher())
        feed = FeedService(
            appContext = mockk(relaxed = true),
            configStore = mockk<ConfigStore>(relaxed = true) { every { config } returns this@GlobalNewAccountReqTest.config },
            nostrService = mockk(relaxed = true),
            feedFilterEngine = mockk(relaxed = true),
            engagementTracker = mockk(relaxed = true),
            blobNoteIndexStore = mockk(relaxed = true),
            contactManager = mockk(relaxed = true),
            imageLoader = mockk(relaxed = true),
            notificationManager = mockk(relaxed = true),
            followingBackupService = mockk(relaxed = true),
            lookupPool = mockk(relaxed = true),
        )
        feed.feedClients["wss://relay.example"] = mockk<WebSocketClient>(relaxed = true) {
            every { send(any()) } answers { sent += firstArg<String>(); true }
        }
        feed._feedMode.value = FeedMode.GLOBAL
    }

    @After
    fun tearDown() = Dispatchers.resetMain()

    /** The filters of the timeline REQ the relay received. */
    private fun primaryFilters(): List<JsonObject> {
        feed.sendPrimaryFeedSubscription("wss://relay.example", "feed-global")
        val req = sent.map { Json.parseToJsonElement(it).jsonArray }.single { it[1].jsonPrimitive.content == "feed-global" }
        return req.drop(2).map { it as JsonObject }
    }

    private fun JsonObject.authors(): List<String>? = (this["authors"] as? JsonArray)?.map { it.jsonPrimitive.content }

    @Test
    fun aNewAccountWithOneFollowAsksForThatFollowByName() {
        // The relay's first graph for this account: the owner and the follow.
        feed._wotPubkeys.value = setOf(owner, follow)
        feed._followedPubkeys.value = listOf(follow)

        val filters = primaryFilters()

        assertEquals(2, filters.size)
        assertEquals(listOf(owner, follow), filters[0].authors())
        assertNull("the open half still asks for everyone", filters[1].authors())
    }

    @Test
    fun theTrustedHalfReachesBackPastAPageOfStrangers() {
        feed._wotPubkeys.value = setOf(owner, follow)
        feed._followedPubkeys.value = listOf(follow)
        val now = System.currentTimeMillis() / 1000
        feed._notes.value = listOf(
            FeedNote.fromEvent("a".repeat(64), stranger, "hi", emptyList(), now - 60, 1),
        )

        val filters = primaryFilters()

        assertEquals(now - 60, filters[1]["since"]!!.jsonPrimitive.long)
        // A week back, not the stranger's minute-old note.
        val trustedSince = filters[0]["since"]!!.jsonPrimitive.long
        assertEquals(true, trustedSince <= now - 7 * 24 * 60 * 60 + 5)
    }

    @Test
    fun everyoneAndAnEmptyWebStayOneOpenFilter() {
        // No graph yet: Global fails closed and waits for it, as on iOS.
        feed._followedPubkeys.value = listOf(follow)
        assertEquals(listOf<List<String>?>(null), primaryFilters().map { it.authors() })

        sent.clear()
        feed._wotPubkeys.value = setOf(owner, follow)
        config.value = HavenConfig(globalShowsEveryone = true)
        assertEquals(listOf<List<String>?>(null), primaryFilters().map { it.authors() })
    }

    @Test
    fun theFirstGraphReasksGlobalOnce() {
        val graph = setOf(owner, follow)
        assertEquals(true, graphArrivalReasksGlobal(emptySet(), graph, FeedMode.GLOBAL, everyone = false))
        assertEquals(false, graphArrivalReasksGlobal(setOf(owner), graph, FeedMode.GLOBAL, everyone = false))
        assertEquals(false, graphArrivalReasksGlobal(emptySet(), graph, FeedMode.FOLLOWING, everyone = false))
        assertEquals(false, graphArrivalReasksGlobal(emptySet(), graph, FeedMode.GLOBAL, everyone = true))
        assertEquals(false, graphArrivalReasksGlobal(emptySet(), emptySet(), FeedMode.GLOBAL, everyone = false))
    }
}
