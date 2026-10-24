package com.nostrvault.ui.screens.profile

import com.nostrvault.data.local.ConfigStore
import com.nostrvault.data.model.FeedProfile
import com.nostrvault.data.model.PostingAccount
import com.nostrvault.service.NostrEvent
import com.nostrvault.service.NostrService
import com.nostrvault.ui.notification.NotificationManager
import io.mockk.coEvery
import io.mockk.coVerify
import io.mockk.every
import io.mockk.mockk
import io.mockk.verify
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.test.StandardTestDispatcher
import kotlinx.coroutines.test.TestScope
import kotlinx.coroutines.test.advanceUntilIdle
import kotlinx.coroutines.test.resetMain
import kotlinx.coroutines.test.runCurrent
import kotlinx.coroutines.test.setMain
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Before
import org.junit.Test

/**
 * Saving the profile publishes after the sheet is gone, behind a lookup of
 * up to 6 s. The signature must be locked to the account that saved, taken
 * at Save, or a switch in that window signs A's profile as B.
 */
@OptIn(ExperimentalCoroutinesApi::class)
class ProfileEditAccountLockTest {

    private val dispatcher = StandardTestDispatcher()

    @Before fun setUp() = Dispatchers.setMain(dispatcher)
    @After fun tearDown() = Dispatchers.resetMain()

    @Test fun theProfileIsSignedLockedToTheAccountThatSaved() {
        val scope = TestScope(dispatcher)
        val lockA = PostingAccount.Lock(npub = "npub-a", hex = "hex-a")
        val lookup = CompletableDeferred<NostrService.ReplaceableLookup>()
        val nostr = mockk<NostrService>(relaxed = true)
        every { nostr.profiles } returns MutableStateFlow(mapOf("hex-a" to FeedProfile(pubkey = "hex-a", name = "a")))
        every { nostr.outboxRelays } returns MutableStateFlow(emptyMap())
        every { nostr.relayLists } returns MutableStateFlow(emptyMap())
        every { nostr.lockPostingAccount() } returns lockA
        coEvery { nostr.lookupNewestReplaceable(0, "hex-a", any(), any(), any()) } coAnswers { lookup.await() }
        coEvery { nostr.signEventAsync(any(), any(), any(), any(), any(), any(), any()) } returns
            NostrEvent("id", "hex-a", 0, 0, emptyList(), "{}", "sig")
        val config = mockk<ConfigStore>()
        every { config.activeAccountHexPubkey } returns MutableStateFlow("hex-a")

        val vm = ProfileEditViewModel(nostr, config, mockk<NotificationManager>(relaxed = true), scope, mockk(relaxed = true))
        vm.open()
        vm.setName("a2")
        vm.save()

        // The lock is taken at Save, before the lookup can finish.
        verify(exactly = 1) { nostr.lockPostingAccount() }
        scope.runCurrent()
        lookup.complete(NostrService.ReplaceableLookup(event = null, asked = 1, answered = 1))
        scope.advanceUntilIdle()

        coVerify(exactly = 1) {
            nostr.signEventAsync(kind = 0, content = any(), tags = any(), password = any(), forceOwner = any(), lockedTo = lockA, silentOnly = any())
        }
    }

    /** A save that failed because of a switch must not reopen as the other account's form. */
    @Test fun aSaveRefusedByASwitchIsNotLaidOverTheOtherAccountsForm() {
        val scope = TestScope(dispatcher)
        val lockA = PostingAccount.Lock(npub = "npub-a", hex = "hex-a")
        val lockB = PostingAccount.Lock(npub = "npub-b", hex = "hex-b")
        val active = MutableStateFlow("hex-a")
        val nostr = mockk<NostrService>(relaxed = true)
        every { nostr.profiles } returns MutableStateFlow(mapOf(
            "hex-a" to FeedProfile(pubkey = "hex-a", name = "a"),
            "hex-b" to FeedProfile(pubkey = "hex-b", name = "b"),
        ))
        every { nostr.outboxRelays } returns MutableStateFlow(emptyMap())
        every { nostr.relayLists } returns MutableStateFlow(emptyMap())
        every { nostr.lockPostingAccount() } answers { if (active.value == "hex-a") lockA else lockB }
        coEvery { nostr.lookupNewestReplaceable(0, "hex-a", any(), any(), any()) } returns
            NostrService.ReplaceableLookup(event = null, asked = 1, answered = 1)
        coEvery { nostr.signEventAsync(any(), any(), any(), any(), any(), any(), any()) } throws
            PostingAccount.AccountChangedException()
        val config = mockk<ConfigStore>()
        every { config.activeAccountHexPubkey } returns active

        val vm = ProfileEditViewModel(nostr, config, mockk<NotificationManager>(relaxed = true), scope, mockk(relaxed = true))
        vm.open()
        vm.setName("a-edited")
        vm.save()
        active.value = "hex-b"
        scope.advanceUntilIdle()

        vm.open()
        assertEquals("b", vm.name.value)
    }

    /**
     * Opened as A, switched to B with the sheet still up (a tapped
     * notification switches first), then dismissed: nothing may be signed,
     * or B's profile becomes A's.
     */
    @Test fun aSwitchBeforeSaveSignsNothing() {
        val scope = TestScope(dispatcher)
        val active = MutableStateFlow("hex-a")
        val nostr = mockk<NostrService>(relaxed = true)
        every { nostr.profiles } returns MutableStateFlow(mapOf(
            "hex-a" to FeedProfile(pubkey = "hex-a", name = "a"),
            "hex-b" to FeedProfile(pubkey = "hex-b", name = "b"),
        ))
        every { nostr.outboxRelays } returns MutableStateFlow(emptyMap())
        every { nostr.relayLists } returns MutableStateFlow(emptyMap())
        every { nostr.lockPostingAccount() } answers { PostingAccount.Lock(npub = "npub-" + active.value, hex = active.value) }
        coEvery { nostr.lookupNewestReplaceable(any(), any(), any(), any(), any()) } returns
            NostrService.ReplaceableLookup(event = null, asked = 1, answered = 1)
        coEvery { nostr.signEventAsync(any(), any(), any(), any(), any(), any(), any()) } returns
            NostrEvent("id", "hex-b", 0, 0, emptyList(), "{}", "sig")
        val config = mockk<ConfigStore>()
        every { config.activeAccountHexPubkey } returns active

        val vm = ProfileEditViewModel(nostr, config, mockk<NotificationManager>(relaxed = true), scope, mockk(relaxed = true))
        vm.open()
        vm.setName("alice-edited")
        active.value = "hex-b"
        vm.save()
        scope.advanceUntilIdle()

        coVerify(exactly = 0) { nostr.signEventAsync(any(), any(), any(), any(), any(), any(), any()) }
        verify(exactly = 0) { nostr.postEvent(any(), any()) }
        vm.open()
        assertEquals("b", vm.name.value)
    }
}
