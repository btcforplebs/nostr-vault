package com.nostrvault.service

import com.nostrvault.data.local.ConfigStore
import com.nostrvault.data.model.TrustRankCopy
import com.nostrvault.relay.HavenConfig
import io.mockk.coEvery
import io.mockk.every
import io.mockk.just
import io.mockk.mockk
import io.mockk.mockkStatic
import io.mockk.Runs
import io.mockk.unmockkStatic
import io.mockk.verify
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.test.UnconfinedTestDispatcher
import kotlinx.coroutines.test.resetMain
import kotlinx.coroutines.test.setMain
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Before
import org.junit.Test

/**
 * A block or unblock changes who Discover asks the local feed store for right
 * away. It used to wait for the next bar move, file read or reopen.
 */
@OptIn(ExperimentalCoroutinesApi::class)
class DiscoveryReachStoreBlockTest {
    private val me = "a".repeat(64)
    private val top = "1".repeat(64)
    private val next = "2".repeat(64)
    private val npub = "npub1me"
    private val config = MutableStateFlow(HavenConfig(ownerNpub = npub))
    private var blockedHex = emptySet<String>()
    private lateinit var feed: FeedService
    private lateinit var store: DiscoveryReachStore

    private val copy = TrustRankCopy(
        account = me, builtAt = 1, maxHop = 4, viewBar = 50.0, floor = 45.0,
        people = mapOf(top to TrustRankCopy.Person(90.0, 3), next to TrustRankCopy.Person(80.0, 4)),
    )

    @Before
    fun setUp() {
        Dispatchers.setMain(UnconfinedTestDispatcher())
        // Extension functions: stub them, or they run on the mock.
        mockkStatic(DISTANT, RECOMPUTE)
        feed = mockk(relaxed = true) { every { blockedHexForActiveAccount() } answers { blockedHex } }
        every { feed.resendDistantPostsRequest() } just Runs
        every { feed.recomputeFilteredNotes() } just Runs
        val configStore = mockk<ConfigStore>(relaxed = true) {
            every { config } returns this@DiscoveryReachStoreBlockTest.config
            every { activeAccountHexPubkey } returns MutableStateFlow(me)
        }
        val copies = mockk<TrustRankCopyStore> { coEvery { copyFor(me) } returns copy }
        store = DiscoveryReachStore(configStore, copies) { feed }
    }

    @After
    fun tearDown() {
        unmockkStatic(DISTANT, RECOMPUTE)
        Dispatchers.resetMain()
    }

    private companion object {
        const val DISTANT = "com.nostrvault.service.FeedServiceDistantPostsKt"
        const val RECOMPUTE = "com.nostrvault.service.FeedServiceFilterRecomputeKt"
    }

    @Test
    fun blockingSomeoneDropsThemFromTheLocalRequestAtOnce() {
        assertEquals(listOf(top, next), store.localDistantAuthors)

        blockedHex = setOf(top)
        config.value = config.value.copy(blockedNpubsPerAccount = mapOf(npub to listOf("npub1top")))
        assertEquals(listOf(next), store.localDistantAuthors)
        verify(exactly = 2) { feed.resendDistantPostsRequest() }

        blockedHex = emptySet()
        config.value = config.value.copy(blockedNpubsPerAccount = emptyMap())
        assertEquals(listOf(top, next), store.localDistantAuthors)
    }
}
