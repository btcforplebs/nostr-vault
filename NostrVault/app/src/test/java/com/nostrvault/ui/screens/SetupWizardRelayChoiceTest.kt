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

    @Before
    fun setUp() {
        Dispatchers.setMain(UnconfinedTestDispatcher())
        val configStore = mockk<ConfigStore>(relaxed = true)
        every { configStore.update(any()) } answers {
            saved = firstArg<(HavenConfig) -> HavenConfig>()(saved)
        }
        viewModel = SetupWizardViewModel(
            configStore = configStore,
            credentialStore = mockk(relaxed = true),
            amberSignerService = mockk(relaxed = true),
            blossomService = mockk(relaxed = true),
            nostrService = mockk(relaxed = true),
            relayImportService = mockk(relaxed = true),
            statsService = mockk(relaxed = true),
            appContext = mockk(relaxed = true),
        )
    }

    @After
    fun tearDown() = Dispatchers.resetMain()

    @Test
    fun `built-in relay keeps the import steps`() {
        viewModel.setSetupPath(SetupPath.FULL)
        assertTrue(WizardStep.IMPORT_NOTES in viewModel.activeSteps)
        assertTrue(WizardStep.MIRROR_MEDIA in viewModel.activeSteps)
    }

    @Test
    fun `external relay skips every step that boots the built-in relay`() {
        for (path in listOf(SetupPath.FULL, SetupPath.BROWSE, SetupPath.NEW_TO_NOSTR, SetupPath.USE_NOSTR)) {
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
    fun `new-to-nostr continues to the intro`() {
        viewModel.choosePath(SetupPath.NEW_TO_NOSTR)
        viewModel.advanceFromRelayChoice()
        assertEquals(WizardStep.NOSTR_INTRO, viewModel.step.value)
        assertFalse(saved.useExternalRelay)
    }

    @Test
    fun `every front door choice goes to the relay choice and back to the front door`() {
        for (path in listOf(SetupPath.FULL, SetupPath.BROWSE, SetupPath.NEW_TO_NOSTR, SetupPath.USE_NOSTR)) {
            viewModel.choosePath(path)
            assertEquals(path, viewModel.setupPath.value)
            assertEquals(WizardStep.RELAY_CHOICE, viewModel.step.value)
            viewModel.goBack()
            assertEquals(WizardStep.WELCOME, viewModel.step.value)
        }
    }

    @Test
    fun `new to nostr is keys, password, profile, done`() {
        viewModel.setSetupPath(SetupPath.NEW_TO_NOSTR)
        assertEquals(
            listOf(WizardStep.NOSTR_INTRO, WizardStep.KEY_PASSWORD, WizardStep.PROFILE, WizardStep.COMPLETE),
            viewModel.activeSteps.drop(2),
        )
    }

    @Test
    fun `the keys page goes to the password page and back`() {
        viewModel.choosePath(SetupPath.NEW_TO_NOSTR)
        viewModel.advanceFromRelayChoice()
        viewModel.advanceFromNostrIntro()
        assertEquals(WizardStep.KEY_PASSWORD, viewModel.step.value)
        viewModel.goBack()
        assertEquals(WizardStep.NOSTR_INTRO, viewModel.step.value)
    }

    @Test
    fun `I already use Nostr is your key, relay check, import tour`() {
        viewModel.setSetupPath(SetupPath.USE_NOSTR)
        assertEquals(
            listOf(WizardStep.USE_NOSTR_KEY, WizardStep.RELAY_CHECK, WizardStep.IMPORT_TOUR),
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
    fun `a public key is read-only and goes to the relay check`() {
        viewModel.choosePath(SetupPath.USE_NOSTR)
        viewModel.advanceFromRelayChoice()
        assertEquals(WizardStep.USE_NOSTR_KEY, viewModel.step.value)
        viewModel.setUseNostrInput("nostr:npub1sg6plzptd64u62a878hep2kev88swjh3tw00gjsfl8f237lmu63q0uf63m")
        viewModel.continueUseNostr()

        assertEquals(WizardStep.RELAY_CHECK, viewModel.step.value)
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
}
