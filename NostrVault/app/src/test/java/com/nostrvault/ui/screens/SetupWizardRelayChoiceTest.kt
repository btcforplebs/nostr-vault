package com.nostrvault.ui.screens

import com.nostrvault.data.local.ConfigStore
import com.nostrvault.relay.HavenConfig
import io.mockk.every
import io.mockk.mockk
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.test.UnconfinedTestDispatcher
import kotlinx.coroutines.test.resetMain
import kotlinx.coroutines.test.setMain
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test

@OptIn(ExperimentalCoroutinesApi::class)
class SetupWizardRelayChoiceTest {

    private var saved = HavenConfig()
    private lateinit var viewModel: SetupWizardViewModel
    private val nostrService = mockk<com.nostrvault.service.NostrService>(relaxed = true)
    private val appContext = mockk<android.content.Context>(relaxed = true)

    @Before
    fun setUp() {
        Dispatchers.setMain(UnconfinedTestDispatcher())
        // Create an account makes its key when it is picked; no native library here.
        io.mockk.mockkObject(com.nostrvault.relay.HavenBridge)
        every { com.nostrvault.relay.HavenBridge.generateKeypair() } returns "11".repeat(32) + ":" + "22".repeat(32)
        every { com.nostrvault.relay.HavenBridge.hexToNpub(any()) } returns "npub1new"
        every { com.nostrvault.relay.HavenBridge.encodeNsec(any()) } returns "nsec1new"
        every { com.nostrvault.relay.HavenBridge.decodeNpub("npub1new") } returns "22".repeat(32)
        io.mockk.mockkObject(com.nostrvault.service.NIP49Service)
        every { com.nostrvault.service.NIP49Service.encrypt(any(), any()) } returns "ncryptsec1new"
        val configStore = mockk<ConfigStore>(relaxed = true)
        every { configStore.update(any()) } answers {
            saved = firstArg<(HavenConfig) -> HavenConfig>()(saved)
        }
        every { configStore.config } answers { kotlinx.coroutines.flow.MutableStateFlow(saved) }
        viewModel = SetupWizardViewModel(
            configStore = configStore,
            credentialStore = mockk(relaxed = true),
            amberSignerService = mockk(relaxed = true),
            blossomService = mockk(relaxed = true),
            nostrService = nostrService,
            relayImportService = mockk(relaxed = true),
            statsService = mockk(relaxed = true),
            appContext = appContext,
            firstRunImport = mockk(relaxed = true) { io.mockk.every { state } returns kotlinx.coroutines.flow.MutableStateFlow(com.nostrvault.service.FirstRunImport.State.Idle) },
        )
    }

    @After
    fun tearDown() {
        io.mockk.unmockkObject(com.nostrvault.relay.HavenBridge, com.nostrvault.service.NIP49Service)
        Dispatchers.resetMain()
    }

    @Test
    fun `built-in relay keeps the import steps`() {
        viewModel.setSetupPath(SetupPath.FULL)
        assertTrue(WizardStep.IMPORT_NOTES in viewModel.activeSteps)
        assertTrue(WizardStep.MIRROR_MEDIA in viewModel.activeSteps)
    }

    @Test
    fun `external relay skips every step that boots the built-in relay`() {
        for (path in listOf(SetupPath.FULL, SetupPath.BROWSE, SetupPath.USE_NOSTR)) {
            viewModel.setSetupPath(path)
            viewModel.setUseExternalRelay(true)
            assertFalse(WizardStep.IMPORT_NOTES in viewModel.activeSteps)
            assertFalse(WizardStep.MIRROR_MEDIA in viewModel.activeSteps)
            assertFalse(WizardStep.RELAY_CHECK in viewModel.activeSteps)
            assertFalse(WizardStep.IMPORT_TOUR in viewModel.activeSteps)
            assertEquals(WizardStep.RELAY_CHOICE, viewModel.activeSteps[1])
        }
    }

    @Test
    fun `choosing an external relay saves it before setup completes`() {
        viewModel.choosePath(SetupPath.FULL)
        viewModel.setUseExternalRelay(true)
        viewModel.setExternalRelayInput("127.0.0.1:4869")
        viewModel.advanceFromRelayChoice()

        assertEquals(WizardStep.ACCOUNT, viewModel.step.value)
        assertTrue(saved.useExternalRelay)
        assertEquals("127.0.0.1:4869", saved.externalRelayURL)
    }

    @Test
    fun `plain ws off the phone is refused`() {
        viewModel.choosePath(SetupPath.BROWSE)
        viewModel.setUseExternalRelay(true)
        viewModel.setExternalRelayInput("ws://relay.example")
        viewModel.advanceFromRelayChoice()

        assertEquals(WizardStep.RELAY_CHOICE, viewModel.step.value)
        assertNotNull(viewModel.error.value)
        assertFalse(saved.useExternalRelay)
    }

    @Test
    fun `a wss relay off the phone is accepted`() {
        viewModel.choosePath(SetupPath.BROWSE)
        viewModel.setUseExternalRelay(true)
        viewModel.setExternalRelayInput("wss://relay.mac.example")
        viewModel.setExternalBlossomInput("https://relay.mac.example")
        viewModel.advanceFromRelayChoice()

        assertTrue(saved.useExternalRelay)
        assertEquals("wss://relay.mac.example", saved.externalRelayURL)
        assertEquals("https://relay.mac.example", saved.externalBlossomURL)
    }

    @Test
    fun `create an account skips the relay choice and makes its key at once`() {
        saved = saved.copy(useExternalRelay = true)
        viewModel.setUseExternalRelay(true)
        viewModel.choosePath(SetupPath.NEW_TO_NOSTR)
        assertEquals(WizardStep.PROFILE, viewModel.step.value)
        assertFalse(saved.useExternalRelay)
        assertFalse(viewModel.useExternalRelay.value)
        assertEquals("nsec1new", viewModel.generatedNsec.value)
        assertEquals("npub1new", saved.ownerNpub)
        // Nothing is locked before the lock step.
        assertEquals(null, saved.ownerNcryptsec)
        viewModel.goBack()
        assertEquals(WizardStep.WELCOME, viewModel.step.value)
    }

    @Test
    fun `every other front door choice goes to the relay choice and back to the front door`() {
        for (path in listOf(SetupPath.FULL, SetupPath.BROWSE, SetupPath.USE_NOSTR)) {
            viewModel.choosePath(path)
            assertEquals(path, viewModel.setupPath.value)
            assertEquals(WizardStep.RELAY_CHOICE, viewModel.step.value)
            viewModel.goBack()
            assertEquals(WizardStep.WELCOME, viewModel.step.value)
        }
    }

    @Test
    fun `new to nostr is profile, who told you, your key, spare, lock, then the feed`() {
        viewModel.setSetupPath(SetupPath.NEW_TO_NOSTR)
        assertEquals(
            listOf(WizardStep.PROFILE, WizardStep.REFERRER, WizardStep.NOSTR_INTRO, WizardStep.KEY_SPARE, WizardStep.KEY_PASSWORD),
            viewModel.activeSteps.drop(1),
        )
    }

    @Test
    fun `profile, people, key, spare and lock go forward and back in order`() {
        viewModel.choosePath(SetupPath.NEW_TO_NOSTR)
        viewModel.advanceFromProfile()
        assertEquals(WizardStep.REFERRER, viewModel.step.value)
        viewModel.advanceFromReferrer()
        assertEquals(WizardStep.NOSTR_INTRO, viewModel.step.value)
        viewModel.advanceFromNostrIntro()
        assertEquals(WizardStep.KEY_SPARE, viewModel.step.value)
        viewModel.advanceFromKeySpare()
        assertEquals(WizardStep.KEY_PASSWORD, viewModel.step.value)
        viewModel.goBack()
        assertEquals(WizardStep.KEY_SPARE, viewModel.step.value)
        viewModel.goBack()
        assertEquals(WizardStep.NOSTR_INTRO, viewModel.step.value)
        viewModel.goBack()
        assertEquals(WizardStep.REFERRER, viewModel.step.value)
        viewModel.goBack()
        assertEquals(WizardStep.PROFILE, viewModel.step.value)
    }

    @Test
    fun `the lock step finishes setup instead of a done screen`() {
        viewModel.choosePath(SetupPath.NEW_TO_NOSTR)
        viewModel.advanceFromProfile()
        viewModel.advanceFromReferrer()
        viewModel.advanceFromNostrIntro()
        viewModel.advanceFromKeySpare()
        viewModel.setPassphrase("longenough")
        viewModel.setConfirmPassphrase("longenough")
        var finished = false
        viewModel.advanceFromKeyPassword { finished = true }
        assertTrue(finished)
        assertTrue(saved.hasCompletedSetup)
        assertNotNull(saved.ownerNcryptsec)
        assertEquals(WizardStep.KEY_PASSWORD, viewModel.step.value)
    }

    @Test
    fun `I already use Nostr is your key, new to Nostr Vault, relay check, import tour`() {
        viewModel.setSetupPath(SetupPath.USE_NOSTR)
        assertEquals(
            listOf(WizardStep.USE_NOSTR_KEY, WizardStep.NEW_TO_VAULT, WizardStep.RELAY_CHECK, WizardStep.IMPORT_TOUR),
            viewModel.activeSteps.drop(2),
        )
    }

    @Test
    fun `I already use Nostr with an external relay ends on the done screen`() {
        viewModel.setSetupPath(SetupPath.USE_NOSTR)
        viewModel.setUseExternalRelay(true)
        assertEquals(listOf(WizardStep.USE_NOSTR_KEY, WizardStep.COMPLETE), viewModel.activeSteps.drop(2))
    }

    @Test
    fun `a public key is read-only and goes to the New to Nostr Vault question`() {
        viewModel.choosePath(SetupPath.USE_NOSTR)
        viewModel.advanceFromRelayChoice()
        assertEquals(WizardStep.USE_NOSTR_KEY, viewModel.step.value)
        viewModel.setUseNostrInput("nostr:npub1sg6plzptd64u62a878hep2kev88swjh3tw00gjsfl8f237lmu63q0uf63m")
        viewModel.continueUseNostr()

        assertEquals(WizardStep.NEW_TO_VAULT, viewModel.step.value)
        assertEquals("npub1sg6plzptd64u62a878hep2kev88swjh3tw00gjsfl8f237lmu63q0uf63m", saved.ownerNpub)
        assertEquals("browse", saved.setupMode)
        assertEquals("browse", saved.signingMode)
    }

    @Test
    fun `a key with a typo fails its checksum`() {
        // jack's npub with its last character changed.
        val typo = com.nostrvault.setup.IdentityInput.parse("npub1sg6plzptd64u62a878hep2kev88swjh3tw00gjsfl8f237lmu63q0uf63n")
        assertFalse(viewModel.keyChecksumOK(typo))
        val good = com.nostrvault.setup.IdentityInput.parse("npub1sg6plzptd64u62a878hep2kev88swjh3tw00gjsfl8f237lmu63q0uf63m")
        assertTrue(viewModel.keyChecksumOK(good))
    }

    @Test
    fun `switching to a public key after Back drops the key pasted before`() {
        saved = saved.copy(ownerHexKey = "ab".repeat(32), ownerNcryptsec = "ncryptsec1old")
        viewModel.choosePath(SetupPath.USE_NOSTR)
        viewModel.advanceFromRelayChoice()
        viewModel.setUseNostrInput("npub1sg6plzptd64u62a878hep2kev88swjh3tw00gjsfl8f237lmu63q0uf63m")
        viewModel.continueUseNostr()
        assertEquals(null, saved.ownerHexKey)
        assertEquals(null, saved.ownerNcryptsec)
    }

    /**
     * Review repro for #409: a key generated on one visit, then another
     * account chosen, then back to New to Nostr. Finishing must not mark or
     * publish for the account that is now the owner, which setup didn't make.
     */
    @Test
    fun `finishing New to Nostr never publishes for an account setup didn't generate`() {
        viewModel.choosePath(SetupPath.NEW_TO_NOSTR)
        // As if a real user's key were the owner by now.
        saved = saved.copy(ownerNpub = "npub1sg6plzptd64u62a878hep2kev88swjh3tw00gjsfl8f237lmu63q0uf63m")
        viewModel.setProfileName("Someone")
        viewModel.completeSetup {}
        Thread.sleep(500) // publishing runs on its own IO coroutine
        assertTrue(saved.hasCompletedSetup) // it really ran to the end

        io.mockk.coVerify(exactly = 0) { nostrService.signEventAsync(any(), any(), any()) }
        io.mockk.verify(exactly = 0) { appContext.getSharedPreferences(any(), any()) }
    }

    @Test
    fun `choosing a way in starts with no key from an earlier visit`() {
        viewModel.choosePath(SetupPath.USE_NOSTR)
        viewModel.setUseNostrInput("nsec1abc")
        viewModel.setUseNostrPassword("secretpass")
        viewModel.choosePath(SetupPath.NEW_TO_NOSTR)
        assertEquals("", viewModel.useNostrInput.value)
        assertEquals("", viewModel.useNostrPassword.value)
        // Create an account made its own key; another way in drops it.
        assertEquals("nsec1new", viewModel.generatedNsec.value)
        viewModel.choosePath(SetupPath.USE_NOSTR)
        assertEquals(null, viewModel.generatedNsec.value)
    }

    @Test
    fun `a pasted nsec needs the New to Nostr password rules`() {
        val nsec = com.nostrvault.setup.IdentityInput.SecretKey("nsec1x")
        viewModel.setUseNostrPassword("short")
        assertEquals("Password must be at least 8 characters", viewModel.useNostrPasswordProblem(nsec))
        viewModel.setUseNostrPassword("longenough")
        viewModel.setUseNostrConfirm("longenougg")
        assertEquals("Passwords do not match", viewModel.useNostrPasswordProblem(nsec))
        viewModel.setUseNostrConfirm("longenough")
        assertEquals(null, viewModel.useNostrPasswordProblem(nsec))
        // An ncryptsec's password already exists; it only has to unlock it.
        viewModel.setUseNostrPassword("x")
        assertEquals(null, viewModel.useNostrPasswordProblem(com.nostrvault.setup.IdentityInput.EncryptedSecretKey("ncryptsec1x")))
    }
}
