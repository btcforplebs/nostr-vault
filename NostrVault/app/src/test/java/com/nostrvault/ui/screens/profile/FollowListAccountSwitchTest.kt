package com.nostrvault.ui.screens.profile

import androidx.lifecycle.SavedStateHandle
import com.nostrvault.data.local.ConfigStore
import com.nostrvault.relay.HavenConfig
import com.nostrvault.service.FeedService
import com.nostrvault.service.NostrService
import io.mockk.every
import io.mockk.mockk
import io.mockk.verify
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.test.UnconfinedTestDispatcher
import kotlinx.coroutines.test.resetMain
import kotlinx.coroutines.test.setMain
import org.junit.After
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test

/**
 * Your Following list, opened as A, left open across a switch to B: it
 * showed B's follows and each tap unfollowed on B. It closes instead, and a
 * tap that lands first does nothing.
 */
@OptIn(ExperimentalCoroutinesApi::class)
class FollowListAccountSwitchTest {
    private val a = "a".repeat(64)
    private val b = "b".repeat(64)
    private val x = "c".repeat(64)

    @Before fun setUp() = Dispatchers.setMain(UnconfinedTestDispatcher())
    @After fun tearDown() = Dispatchers.resetMain()

    @Test fun aSwitchClosesTheListAndItsButtonsDoNothing() {
        val active = MutableStateFlow(a)
        val config = mockk<ConfigStore>(relaxed = true)
        every { config.activeAccountHexPubkey } returns active
        every { config.config } returns MutableStateFlow(HavenConfig())
        val nostr = mockk<NostrService>(relaxed = true)
        every { nostr.configStore } returns config
        every { nostr.profiles } returns MutableStateFlow(emptyMap())
        every { nostr.outboxRelays } returns MutableStateFlow(emptyMap())
        every { nostr._outboxRelays } returns MutableStateFlow(emptyMap())
        every { nostr.relayLists } returns MutableStateFlow(emptyMap())
        val feed = mockk<FeedService>(relaxed = true)
        every { feed.followedPubkeys } returns MutableStateFlow(listOf(x))
        every { feed.extendedNetworkPubkeys } returns MutableStateFlow(emptyList())
        every { feed.isFollowing(x) } returns true

        val vm = FollowListViewModel(SavedStateHandle(mapOf("pubkey" to a)), nostr, feed, config)
        assertTrue(vm.isOwn)
        assertFalse(vm.accountChanged.value)

        active.value = b
        assertTrue(vm.accountChanged.value)
        vm.toggle(x)
        verify(exactly = 0) { feed.unfollowUser(any(), any()) }
        verify(exactly = 0) { feed.followUser(any(), any()) }

        // Same account: the button works.
        active.value = a
        vm.toggle(x)
        verify(exactly = 1) { feed.unfollowUser(x, any()) }
    }
}
