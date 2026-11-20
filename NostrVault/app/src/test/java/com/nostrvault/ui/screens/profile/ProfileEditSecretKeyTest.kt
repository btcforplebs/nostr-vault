package com.nostrvault.ui.screens.profile

import com.nostrvault.data.local.ConfigStore
import com.nostrvault.data.model.FeedProfile
import com.nostrvault.data.model.PostingAccount
import com.nostrvault.relay.HavenBridge
import com.nostrvault.service.NostrEvent
import com.nostrvault.service.NostrService
import com.nostrvault.ui.notification.NotificationManager
import com.nostrvault.ui.notification.ErrorStyle
import io.mockk.slot
import com.nostrvault.util.SecretKeyLeak
import com.nostrvault.util.SecretKeyLeakException
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
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test
import java.security.SecureRandom

/** Save never publishes a secret key typed into a field, and the field keeps it to take out. */
@OptIn(ExperimentalCoroutinesApi::class)
class ProfileEditSecretKeyTest {

    private val dispatcher = StandardTestDispatcher()
    private val scope = TestScope(dispatcher)
    private val lock = PostingAccount.Lock(npub = "npub-a", hex = "hex-a")
    private val nostr = mockk<NostrService>(relaxed = true)
    private val notifications = mockk<NotificationManager>(relaxed = true)

    /** A throwaway key made for this run. */
    private val nsec: String = ByteArray(32).also { SecureRandom().nextBytes(it); it[0] = 1 }
        .joinToString("") { "%02x".format(it) }.let { HavenBridge.encodeNsec(it)!! }

    @Before fun setUp() {
        Dispatchers.setMain(dispatcher)
        every { nostr.profiles } returns MutableStateFlow(mapOf("hex-a" to FeedProfile(pubkey = "hex-a", name = "a")))
        every { nostr.outboxRelays } returns MutableStateFlow(emptyMap())
        every { nostr.relayLists } returns MutableStateFlow(emptyMap())
        every { nostr.lockPostingAccount() } returns lock
        coEvery { nostr.lookupNewestReplaceable(0, "hex-a", any(), any(), any()) } returns
            NostrService.ReplaceableLookup(event = null, asked = 1, answered = 1)
        coEvery { nostr.signEventAsync(any(), any(), any(), any(), any(), any(), any(), any()) } returns
            NostrEvent("id", "hex-a", 0, 0, emptyList(), "{}", "sig")
    }

    @After fun tearDown() = Dispatchers.resetMain()

    private fun viewModel(): ProfileEditViewModel {
        val config = mockk<ConfigStore>()
        every { config.activeAccountHexPubkey } returns MutableStateFlow("hex-a")
        return ProfileEditViewModel(nostr, config, notifications, scope, mockk(relaxed = true))
    }

    @Test fun aKeyInTheNameIsRefusedAndStaysInTheField() {
        val vm = viewModel()
        vm.open()
        vm.setName(nsec)
        assertFalse(vm.save())
        scope.advanceUntilIdle()

        assertEquals(SecretKeyLeak.MESSAGE, vm.saveError.value)
        assertEquals(nsec, vm.name.value)
        coVerify(exactly = 0) { nostr.signEventAsync(any(), any(), any(), any(), any(), any(), any(), any()) }
        verify(exactly = 0) { nostr.postEvent(any(), any()) }
    }

    @Test fun takingTheKeyOutLetsTheSaveGo() {
        val vm = viewModel()
        vm.open()
        vm.setAbout("hello $nsec")
        assertFalse(vm.save())
        vm.setAbout("hello")
        assertTrue(vm.save())
        scope.advanceUntilIdle()

        assertNull(vm.saveError.value)
        coVerify(exactly = 1) { nostr.signEventAsync(0, any(), any(), any(), any(), any(), any(), any()) }
    }

    /** A key in a field this form doesn't show: the signer refuses it, and the error says why. */
    @Test fun aKeyTheSignerRefusesSaysSo() {
        coEvery { nostr.signEventAsync(any(), any(), any(), any(), any(), any(), any(), any()) } throws SecretKeyLeakException()
        val vm = viewModel()
        vm.open()
        vm.setName("a2")
        assertTrue(vm.save())
        scope.advanceUntilIdle()

        verify(exactly = 1) { notifications.showError(SecretKeyLeak.MESSAGE) }
        verify(exactly = 0) { nostr.postEvent(any(), any()) }
    }

    /** A key in a field and a tag the form doesn't show: left out, the user told where, the edit published. */
    @Test fun aKeyInAHiddenFieldIsLeftOutAndNamed() {
        val newest = NostrEvent(
            "old", "hex-a", 1, 0,
            listOf(listOf("i", "github:$nsec", "proof"), listOf("i", "twitter:me", "p")),
            """{"name":"a","displayName":"$nsec","lud06":"lnurl1x"}""", "sig",
        )
        coEvery { nostr.lookupNewestReplaceable(0, "hex-a", any(), any(), any()) } returns
            NostrService.ReplaceableLookup(event = newest, asked = 1, answered = 1)
        val content = slot<String>()
        val tags = slot<List<List<String>>>()
        coEvery { nostr.signEventAsync(0, capture(content), capture(tags), any(), any(), any(), any(), any()) } returns
            NostrEvent("id", "hex-a", 2, 0, emptyList(), "{}", "sig")
        val vm = viewModel()
        vm.open()
        vm.setName("a2")
        assertTrue(vm.save())
        scope.advanceUntilIdle()

        assertFalse(content.captured.contains("nsec1"))
        assertFalse(tags.captured.flatten().any { it.contains("nsec1") })
        assertTrue(content.captured.contains("\"lud06\":\"lnurl1x\""))
        assertTrue(content.captured.contains("\"name\":\"a2\""))
        assertEquals(listOf(listOf("i", "twitter:me", "p")), tags.captured)
        verify(exactly = 1) { notifications.showError("Removed a secret key from displayName, tag i.", ErrorStyle.WARNING) }
        verify(exactly = 1) { nostr.postEvent(any(), any()) }
    }
}
