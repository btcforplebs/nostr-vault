package com.nostrvault.service

import com.nostrvault.data.local.ConfigStore
import com.nostrvault.data.local.CredentialStore
import com.nostrvault.relay.AccountBunkerConfig
import com.nostrvault.relay.HavenConfig
import io.mockk.every
import io.mockk.mockk
import io.mockk.mockkObject
import io.mockk.unmockkObject
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.emptyFlow
import kotlinx.coroutines.test.UnconfinedTestDispatcher
import kotlinx.coroutines.test.resetMain
import kotlinx.coroutines.test.setMain
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Before
import org.junit.Test

/**
 * Which crypto the DM paths may use for the ACTIVE account.
 *
 * Android used to ask one question — "is the owner's global signing mode
 * amber?" — and otherwise reach for the owner's key. So a bunker (NIP-46) or
 * watch-only account dropped every inbound DM and threw on every send, and a
 * second account's DMs were sealed with the OWNER's key (never delivered, and
 * linking the two accounts).
 */
@OptIn(ExperimentalCoroutinesApi::class)
class DMCryptoModeTest {

    private val ownerNpub = "npub1owner"
    private val secondNpub = "npub1second"
    private val ownerHex = "a".repeat(64)

    private val config = MutableStateFlow(HavenConfig())
    private lateinit var service: DMService

    @Before
    fun setUp() {
        Dispatchers.setMain(UnconfinedTestDispatcher())
        mockkObject(CredentialStore)
        every { CredentialStore.getKeychainPassword(any()) } returns null
        every { CredentialStore.getNsec(any()) } returns null
        every { CredentialStore.getCredentialHexKey(any()) } returns null

        val configStore = mockk<ConfigStore>(relaxed = true)
        every { configStore.config } returns config
        every { configStore.accountSwitches } returns emptyFlow()
        val nostrService = mockk<NostrService>(relaxed = true)
        every { nostrService.ownerHexPubkey } returns ownerHex

        service = DMService(
            configStore = configStore,
            credentialStore = CredentialStore,
            nostrService = nostrService,
            amberSignerService = mockk(relaxed = true),
            feedService = stubFeedService(),
        )
    }

    @After
    fun tearDown() {
        unmockkObject(CredentialStore)
        Dispatchers.resetMain()
    }

    @Test
    fun `an owner with a local key uses it`() {
        config.value = HavenConfig(ownerNpub = ownerNpub, ownerHexKey = "b".repeat(64))
        assertEquals(DMCrypto.LOCAL, service.dmCryptoMode())
    }

    @Test
    fun `a watch-only account has no DM crypto at all`() {
        // npub-only: nothing to decrypt with and nothing to seal with. This used
        // to look like "local key mode" and silently drop every DM.
        config.value = HavenConfig(ownerNpub = ownerNpub)
        assertEquals(DMCrypto.NONE, service.dmCryptoMode())
        assertEquals(true, service.dmUnavailableReason() != null)
    }

    @Test
    fun `a bunker account signs through the bunker, not a missing local key`() {
        config.value = HavenConfig(
            ownerNpub = ownerNpub,
            accountSigningModes = mapOf(ownerNpub to "nip46"),
            accountBunkerConfigs = mapOf(ownerNpub to bunker()),
        )
        assertEquals(DMCrypto.BUNKER, service.dmCryptoMode())
        assertEquals(null, service.dmUnavailableReason())
    }

    @Test
    fun `a second account on Amber is read per account, not from the owner's mode`() {
        config.value = HavenConfig(
            ownerNpub = ownerNpub,
            ownerHexKey = "b".repeat(64),
            signingMode = "local",
            activeAccountNpub = secondNpub,
            accountNpubs = listOf(secondNpub),
            accountSigningModes = mapOf(secondNpub to "amber"),
        )
        assertEquals(DMCrypto.AMBER, service.dmCryptoMode())
    }

    @Test
    fun `a second account with its own stored key is local, and the owner's key is irrelevant`() {
        every { CredentialStore.getCredentialHexKey(secondNpub) } returns "c".repeat(64)
        config.value = HavenConfig(
            ownerNpub = ownerNpub,
            ownerHexKey = "b".repeat(64),
            activeAccountNpub = secondNpub,
            accountNpubs = listOf(secondNpub),
        )
        assertEquals(DMCrypto.LOCAL, service.dmCryptoMode())
    }

    @Test
    fun `a second account with no key of its own is watch-only, even when the owner has one`() {
        // The old resolver answered with the OWNER's key here, so the seal was
        // signed by the owner while the rumor claimed the second account —
        // which every correct client (this one included) drops.
        config.value = HavenConfig(
            ownerNpub = ownerNpub,
            ownerHexKey = "b".repeat(64),
            activeAccountNpub = secondNpub,
            accountNpubs = listOf(secondNpub),
        )
        assertEquals(DMCrypto.NONE, service.dmCryptoMode())
    }

    @Test
    fun `an encrypted owner key counts only while its password is stored`() {
        config.value = HavenConfig(ownerNpub = ownerNpub, ownerNcryptsec = "ncryptsec1x")
        assertEquals(DMCrypto.NONE, service.dmCryptoMode())

        every { CredentialStore.getKeychainPassword(ownerNpub) } returns "hunter2"
        assertEquals(DMCrypto.LOCAL, service.dmCryptoMode())
    }

    private fun bunker() = AccountBunkerConfig(
        bunkerURI = "bunker://${"d".repeat(64)}?relay=wss://relay.example",
        signerPubkey = "d".repeat(64),
        clientSecretKey = "e".repeat(64),
    )
}
