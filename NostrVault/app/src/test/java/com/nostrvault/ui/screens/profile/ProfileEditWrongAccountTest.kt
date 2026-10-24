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
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test

/**
 * Edit Profile saved over the wrong account's profile on a phone with two
 * accounts (Logen, 2026-10-24). A kind 0 may only be signed by the account
 * the form was filled from, for that account's own profile.
 */
@OptIn(ExperimentalCoroutinesApi::class)
class ProfileEditWrongAccountTest {

    private val dispatcher = StandardTestDispatcher()

    @Before fun setUp() = Dispatchers.setMain(dispatcher)
    @After fun tearDown() = Dispatchers.resetMain()

    private val active = MutableStateFlow("hex-a")

    private fun nostr(signedAs: String? = null): NostrService {
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
        coEvery { nostr.signEventAsync(any(), any(), any(), any(), any(), any(), any()) } answers {
            NostrEvent("id", signedAs ?: active.value, 0, 0, emptyList(), "{}", "sig")
        }
        return nostr
    }

    private fun viewModel(nostr: NostrService, scope: TestScope): ProfileEditViewModel {
        val config = mockk<ConfigStore>()
        every { config.activeAccountHexPubkey } returns active
        return ProfileEditViewModel(nostr, config, mockk<NotificationManager>(relaxed = true), scope, mockk(relaxed = true))
    }

    @Test fun onlyTheEditedAccountMaySignItsProfile() {
        assertTrue(ProfileEditGuard.maySign(signer = "hex-a", editedProfile = "hex-a", formAccount = "hex-a"))
        assertFalse(ProfileEditGuard.maySign(signer = "hex-b", editedProfile = "hex-a", formAccount = "hex-a"))
        assertFalse(ProfileEditGuard.maySign(signer = "hex-a", editedProfile = "hex-b", formAccount = "hex-a"))
        assertFalse(ProfileEditGuard.maySign(signer = "hex-a", editedProfile = "hex-a", formAccount = "hex-b"))
        assertFalse(ProfileEditGuard.maySign(signer = "", editedProfile = "", formAccount = ""))
        assertTrue(ProfileEditGuard.maySign(signer = "ABCD", editedProfile = "abcd", formAccount = "abcd"))
    }

    /**
     * A's save failed while A was active (offline), so A's fields were kept
     * for the next open. Switched to B, the next open must show B's profile:
     * laying A's fields over it made the next save publish them as B.
     */
    @Test fun aFailedSavesDraftDoesNotFillTheNextAccountsForm() {
        val scope = TestScope(dispatcher)
        val nostr = nostr()
        coEvery { nostr.lookupNewestReplaceable(0, "hex-a", any(), any(), any()) } returns
            NostrService.ReplaceableLookup(event = null, asked = 1, answered = 0)
        val vm = viewModel(nostr, scope)

        vm.open()
        vm.setName("a-edited")
        vm.save()
        scope.advanceUntilIdle()
        verify(exactly = 0) { nostr.postEvent(any(), any()) }

        active.value = "hex-b"
        vm.open()
        assertEquals("b", vm.name.value)
        assertFalse(vm.hasChanges())

        // Back on A, the draft is still A's.
        active.value = "hex-a"
        vm.open()
        assertEquals("a-edited", vm.name.value)
    }

    /** A signer that hands back another key's signature is never published. */
    @Test fun aKind0SignedByAnotherKeyIsNotPublished() {
        val scope = TestScope(dispatcher)
        val nostr = nostr(signedAs = "hex-b")
        val vm = viewModel(nostr, scope)

        vm.open()
        vm.setName("a-edited")
        vm.save()
        scope.advanceUntilIdle()

        verify(exactly = 0) { nostr.postEvent(any(), any()) }
    }

    @Test fun theSaveButtonPublishesAsTheFormsAccount() {
        val scope = TestScope(dispatcher)
        val nostr = nostr()
        val vm = viewModel(nostr, scope)

        vm.open()
        vm.setName("a-edited")
        vm.save()
        scope.advanceUntilIdle()

        verify(exactly = 1) { nostr.postEvent(match { it.pubkey == "hex-a" && it.kind == 0 }, any()) }
    }

    /** Swipe, Back or a tap outside close without saving; only the Save button saves. */
    @Test fun closingTheSheetNeverSaves() {
        val scope = TestScope(dispatcher)
        val nostr = nostr()
        val vm = viewModel(nostr, scope)

        vm.open()
        vm.setName("a-edited")
        vm.close()
        scope.advanceUntilIdle()

        coVerify(exactly = 0) { nostr.signEventAsync(any(), any(), any(), any(), any(), any(), any()) }
        verify(exactly = 0) { nostr.postEvent(any(), any()) }
        // A changed form can't be swiped or backed away by accident.
        assertFalse(ProfileEditGuard.closesOnSwipe(hasChanges = true, uploading = false))
        assertTrue(ProfileEditGuard.closesOnSwipe(hasChanges = false, uploading = false))
        assertFalse(ProfileEditGuard.closesOnSwipe(hasChanges = false, uploading = true))
    }
}
