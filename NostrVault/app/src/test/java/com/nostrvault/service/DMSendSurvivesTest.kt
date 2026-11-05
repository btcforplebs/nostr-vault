package com.nostrvault.service

import com.nostrvault.data.local.ConfigStore
import com.nostrvault.data.local.CredentialStore
import com.nostrvault.relay.HavenConfig
import io.mockk.coEvery
import io.mockk.every
import io.mockk.mockk
import io.mockk.mockkObject
import io.mockk.unmockkObject
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.async
import kotlinx.coroutines.cancel
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.emptyFlow
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.test.UnconfinedTestDispatcher
import kotlinx.coroutines.test.resetMain
import kotlinx.coroutines.test.setMain
import kotlinx.coroutines.withTimeoutOrNull
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test
import java.io.File
import java.nio.file.Files

/**
 * A NIP-17 send is not tied to the screen that started it, and a message
 * that never went out does not stay in the thread looking sent: not when the
 * thread is left mid-send (bug 1), and not when the account changes while
 * the signer is still sealing (bug 3).
 */
@OptIn(ExperimentalCoroutinesApi::class)
class DMSendSurvivesTest {
    private val owner = "npub1owner"
    private val accountA = "a".repeat(64)
    private val accountB = "b".repeat(64)
    private val recipient = "c".repeat(64)
    private val wrapId = "d".repeat(64)
    private val wrap = """{"id":"$wrapId","kind":1059,"pubkey":"${"e".repeat(64)}","content":"x","tags":[],"created_at":1,"sig":"f"}"""

    private lateinit var dir: File
    private val activeHex = MutableStateFlow(accountA)
    /** NostrService's view of the active account; blank keeps the switch off the network. */
    @Volatile private var nostrActive = accountA
    private val signer = CompletableDeferred<String?>()
    private lateinit var service: DMService

    @Before
    fun setUp() {
        Dispatchers.setMain(UnconfinedTestDispatcher())
        dir = Files.createTempDirectory("dm-send").toFile()
        mockkObject(CredentialStore)
        every { CredentialStore.getKeychainPassword(any()) } returns null
        every { CredentialStore.getNsec(any()) } returns null
        every { CredentialStore.getCredentialHexKey(any()) } returns null
        mockkObject(NIP17Service)
        // Amber holding the seal until the test answers for it.
        coEvery { NIP17Service.createGiftWrappedDMWithAmber(any(), any(), any(), any()) } coAnswers { signer.await() }

        val config = MutableStateFlow(
            HavenConfig(
                ownerNpub = owner,
                accountSigningModes = mapOf(owner to "amber"),
                appSupportDir = dir.absolutePath,
                dmRelays = emptyList(),
            )
        )
        val configStore = mockk<ConfigStore>(relaxed = true)
        every { configStore.config } returns config
        every { configStore.accountSwitches } returns emptyFlow()
        every { configStore.activeAccountHexPubkey } returns activeHex
        val nostr = mockk<NostrService>(relaxed = true)
        every { nostr.activeHexPubkey } answers { nostrActive }
        every { nostr.relayLists } returns MutableStateFlow(emptyMap())
        // Unreachable on purpose: the publish is fire-and-forget either way.
        every { nostr.dmRelayLists } returns MutableStateFlow(mapOf(recipient to listOf("wss://relay.invalid")))
        service = DMService(
            configStore = configStore,
            credentialStore = CredentialStore,
            nostrService = nostr,
            amberSignerService = mockk(relaxed = true),
            feedService = stubFeedService(),
        )
        service.loadedCacheKey = accountA
    }

    @After
    fun tearDown() {
        // Sockets the send and the switch opened must not outlive the test's Main.
        service.scope.cancel()
        unmockkObject(NIP17Service)
        unmockkObject(CredentialStore)
        Dispatchers.resetMain()
        dir.deleteRecursively()
    }

    private fun bubbles(): List<DMMessage> =
        service.conversations.value.firstOrNull { it.id == recipient }?.messages.orEmpty()

    private suspend fun waitFor(timeoutMs: Long = 3_000, check: () -> Boolean): Boolean =
        withTimeoutOrNull(timeoutMs) {
            while (!check()) delay(20)
            true
        } ?: false

    @Test
    fun `leaving the thread mid-send keeps the send going`() = runBlocking {
        val screen = async(Dispatchers.Default) { service.sendMessage(recipient, "hunt test one") }
        assertTrue(waitFor { bubbles().size == 1 })
        screen.cancel() // Back: the thread's viewModelScope goes away

        signer.complete(wrap)
        assertTrue("the wraps were never published", waitFor { wrapId in service.sentSelfWrapIds })
        assertEquals("hunt test one", bubbles().single().content)
    }

    @Test
    fun `a send that fails after the thread is left does not stay looking sent`() = runBlocking {
        val screen = async(Dispatchers.Default) { service.sendMessage(recipient, "hunt test one") }
        assertTrue(waitFor { bubbles().size == 1 })
        screen.cancel()

        signer.complete(null) // Amber refuses the seal
        assertTrue("the failed message is still in the thread", waitFor { bubbles().isEmpty() })
    }

    @Test
    fun `an account switch mid-send fails loudly and takes the bubble out of the old inbox`() = runBlocking {
        val screen = async(Dispatchers.Default) { runCatching { service.sendMessage(recipient, "for A only") } }
        assertTrue(waitFor { bubbles().size == 1 })

        nostrActive = "" // no live subscriptions for B in a unit test
        activeHex.value = accountB
        service.switchAccount() // saves A's inbox, bubble included, and starts B's
        signer.complete(wrap)

        val result = withTimeoutOrNull(3_000) { screen.await() }
        assertTrue("the send never finished", result != null)
        assertTrue("the send returned as if it went out", result!!.isFailure)
        assertTrue(result.exceptionOrNull()!!.message!!.contains("account", ignoreCase = true))
        assertFalse(wrapId in service.sentSelfWrapIds)

        val cacheA = File(dir, "dm_cache_$accountA.json")
        assertTrue(
            "A's saved inbox still shows the message as sent",
            waitFor { cacheA.exists() && !cacheA.readText().contains("for A only") },
        )
    }
}
