package com.nostrvault.service

import com.nostrvault.data.local.ConfigStore
import com.nostrvault.data.model.FeedNote
import com.nostrvault.data.model.TrustGate
import com.nostrvault.relay.HavenConfig
import io.mockk.every
import io.mockk.mockk
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.test.StandardTestDispatcher
import kotlinx.coroutines.test.resetMain
import kotlinx.coroutines.test.setMain
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Before
import org.junit.Test
import java.util.Date

/**
 * A note's thread keeps to your web whatever Global's Everyone shield says
 * (Logen 2026-11-24, iOS `NoteDetailView.replyGate`). With the shield on
 * Everyone the thread used the Global set, which is null, so every stranger's
 * reply showed with no "Outside your web" fold.
 */
@OptIn(ExperimentalCoroutinesApi::class)
class ThreadTrustSetTest {
    private val owner = "0".repeat(64)
    private val follow = "f".repeat(64)
    private val webFriend = "a".repeat(64)
    private val blocked = "b".repeat(64)
    private val stranger = "5".repeat(64)
    private val config = MutableStateFlow(HavenConfig())
    private lateinit var feed: FeedService

    @Before
    fun setUp() {
        Dispatchers.setMain(StandardTestDispatcher())
        feed = FeedService(
            appContext = mockk(relaxed = true),
            configStore = mockk<ConfigStore>(relaxed = true) { every { config } returns this@ThreadTrustSetTest.config },
            nostrService = mockk(relaxed = true) {
                every { npubToHex("npub1blocked") } returns blocked
                every { activeHexPubkey } returns owner
            },
            feedFilterEngine = mockk(relaxed = true),
            engagementTracker = mockk(relaxed = true),
            blobNoteIndexStore = mockk(relaxed = true),
            contactManager = mockk(relaxed = true),
            imageLoader = mockk(relaxed = true),
            notificationManager = mockk(relaxed = true),
            followingBackupService = mockk(relaxed = true),
            lookupPool = mockk(relaxed = true),
            discoveryReach = mockk(relaxed = true),
        )
        feed._wotPubkeys.value = setOf(owner, webFriend, blocked)
        feed._followedPubkeys.value = listOf(follow)
    }

    @After
    fun tearDown() = Dispatchers.resetMain()

    private fun reply(id: String, pubkey: String) = FeedNote(
        id = id, pubkey = pubkey, content = "", createdAt = Date(0),
        tags = listOf(listOf("e", "root", "", "root")), kind = 1, repostedBy = null,
        isReply = true, replyToPubkey = null, parentEventId = "root",
        mediaURLs = emptyList(), linkURLs = emptyList(), quotedEventIds = emptyList(), repostedEventId = null,
    )

    @Test
    fun theEveryoneShieldDoesNotOpenTheThread() {
        config.value = HavenConfig(globalShowsEveryone = true)
        assertNull("Global itself is open", feed.globalTrustSet())

        val replies = listOf(reply("1", webFriend), reply("2", stranger), reply("3", follow))
        val (inside, outside) = TrustGate.splitThread(replies, feed.threadTrustSet(), setOf(owner))

        assertEquals(listOf("1", "3"), inside.map { it.id })
        assertEquals(listOf("2"), outside.map { it.id })
    }

    @Test
    fun theThreadSetIsTheFeedsWebWithoutBlocks() {
        config.value = HavenConfig(
            ownerNpub = "npub1owner",
            privateBlockedNpubsPerAccount = mapOf("npub1owner" to listOf("npub1blocked")),
        )
        val shieldOff = feed.threadTrustSet()
        assertEquals(feed.globalTrustSet(), shieldOff)
        assertEquals(setOf(owner, webFriend, follow), shieldOff)

        config.value = config.value.copy(globalShowsEveryone = true)
        assertEquals("the shield changes nothing here", shieldOff, feed.threadTrustSet())
    }
}
