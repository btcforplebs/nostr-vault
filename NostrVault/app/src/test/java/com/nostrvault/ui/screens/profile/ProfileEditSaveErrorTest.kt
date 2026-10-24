package com.nostrvault.ui.screens.profile

import com.nostrvault.data.local.ConfigStore
import com.nostrvault.data.model.FeedProfile
import com.nostrvault.data.model.PostingAccount
import com.nostrvault.service.BroadcastTally
import com.nostrvault.service.NostrEvent
import com.nostrvault.service.NostrService
import com.nostrvault.ui.notification.NotificationManager
import io.mockk.coEvery
import io.mockk.every
import io.mockk.mockk
import io.mockk.verify
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.test.StandardTestDispatcher
import kotlinx.coroutines.test.TestScope
import kotlinx.coroutines.test.advanceUntilIdle
import kotlinx.coroutines.test.resetMain
import kotlinx.coroutines.test.setMain
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Before
import org.junit.Test

/** The save error says what iOS says: not sent, or sent and no relay took it. */
@OptIn(ExperimentalCoroutinesApi::class)
class ProfileEditSaveErrorTest {

    private val dispatcher = StandardTestDispatcher()
    private val scope = TestScope(dispatcher)
    private val lock = PostingAccount.Lock(npub = "npub-a", hex = "hex-a")
    private val nostr = mockk<NostrService>(relaxed = true)
    private val notifications = mockk<NotificationManager>(relaxed = true)
    /** Each publish's broadcast callback, in order. */
    private val outcomes = mutableListOf<(BroadcastTally.Outcome) -> Unit>()

    @Before fun setUp() {
        Dispatchers.setMain(dispatcher)
        every { nostr.profiles } returns MutableStateFlow(mapOf("hex-a" to FeedProfile(pubkey = "hex-a", name = "a")))
        every { nostr.outboxRelays } returns MutableStateFlow(emptyMap())
        every { nostr.relayLists } returns MutableStateFlow(emptyMap())
        every { nostr.lockPostingAccount() } returns lock
        coEvery { nostr.signEventAsync(any(), any(), any(), any(), any(), any(), any()) } returns
            NostrEvent("id", "hex-a", 0, 0, emptyList(), "{}", "sig")
        every { nostr.postEvent(any(), any()) } answers { outcomes += secondArg<(BroadcastTally.Outcome) -> Unit>() }
    }

    @After fun tearDown() = Dispatchers.resetMain()

    private fun viewModel(): ProfileEditViewModel {
        val config = mockk<ConfigStore>()
        every { config.activeAccountHexPubkey } returns MutableStateFlow("hex-a")
        return ProfileEditViewModel(nostr, config, notifications, scope, mockk(relaxed = true))
    }

    private fun save(vm: ProfileEditViewModel, name: String) {
        vm.open()
        vm.setName(name)
        vm.save()
        scope.advanceUntilIdle()
    }

    private fun lookupAnswers(found: Boolean) {
        coEvery { nostr.lookupNewestReplaceable(0, "hex-a", any(), any(), any()) } returns
            NostrService.ReplaceableLookup(event = null, asked = 1, answered = if (found) 1 else 0)
    }

    @Test fun aSaveThatNeverWentOutSaysTryAgain() {
        lookupAnswers(found = false)
        val vm = viewModel()
        save(vm, "a2")

        verify(exactly = 1) { notifications.showError(ProfileEditViewModel.SAVE_FAILED) }
        verify(exactly = 0) { notifications.showError(ProfileEditViewModel.SAVE_REFUSED) }
        vm.open()
        assertEquals("a2", vm.name.value)
    }

    @Test fun aSaveNoRelayTookSaysSoAndKeepsTheChanges() {
        lookupAnswers(found = true)
        val vm = viewModel()
        save(vm, "a2")
        verify(exactly = 0) { notifications.showError(any()) }

        outcomes.single()(BroadcastTally.Outcome.REFUSED)
        scope.advanceUntilIdle()

        verify(exactly = 1) { notifications.showError(ProfileEditViewModel.SAVE_REFUSED) }
        verify { nostr.showLocalProfile("hex-a", FeedProfile(pubkey = "hex-a", name = "a")) }
        vm.open()
        assertEquals("a2", vm.name.value)
    }

    @Test fun anAcceptedSaveSaysNothing() {
        lookupAnswers(found = true)
        val vm = viewModel()
        save(vm, "a2")
        outcomes.single()(BroadcastTally.Outcome.ACCEPTED)
        scope.advanceUntilIdle()

        verify(exactly = 0) { notifications.showError(any()) }
    }

    /** A late refusal of an older save must not undo the newer one shown now. */
    @Test fun aLateRefusalOfAnOlderSaveIsIgnored() {
        lookupAnswers(found = true)
        val vm = viewModel()
        save(vm, "a2")
        save(vm, "a3")

        outcomes.first()(BroadcastTally.Outcome.REFUSED)
        scope.advanceUntilIdle()

        verify(exactly = 0) { notifications.showError(any()) }
    }
}
