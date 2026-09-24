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
        for (path in listOf(SetupPath.FULL, SetupPath.BROWSE, SetupPath.NEW_TO_NOSTR)) {
            viewModel.setSetupPath(path)
            viewModel.setUseExternalRelay(true)
            assertFalse(WizardStep.IMPORT_NOTES in viewModel.activeSteps)
            assertFalse(WizardStep.MIRROR_MEDIA in viewModel.activeSteps)
            assertEquals(WizardStep.RELAY_CHOICE, viewModel.activeSteps[2])
        }
    }

    @Test
    fun `choosing an external relay saves it before setup completes`() {
        viewModel.setSetupPath(SetupPath.FULL)
        viewModel.advanceFromChoosePath()
        viewModel.setUseExternalRelay(true)
        viewModel.setExternalRelayInput("127.0.0.1:4869")
        viewModel.advanceFromRelayChoice()

        assertEquals(WizardStep.ACCOUNT, viewModel.step.value)
        assertTrue(saved.useExternalRelay)
        assertEquals("127.0.0.1:4869", saved.externalRelayURL)
    }

    @Test
    fun `an address off the phone is refused`() {
        viewModel.setSetupPath(SetupPath.BROWSE)
        viewModel.advanceFromChoosePath()
        viewModel.setUseExternalRelay(true)
        viewModel.setExternalRelayInput("wss://relay.example")
        viewModel.advanceFromRelayChoice()

        assertEquals(WizardStep.RELAY_CHOICE, viewModel.step.value)
        assertNotNull(viewModel.error.value)
        assertFalse(saved.useExternalRelay)
    }

    @Test
    fun `new-to-nostr continues to the intro`() {
        viewModel.setSetupPath(SetupPath.NEW_TO_NOSTR)
        viewModel.advanceFromChoosePath()
        viewModel.advanceFromRelayChoice()
        assertEquals(WizardStep.NOSTR_INTRO, viewModel.step.value)
        assertFalse(saved.useExternalRelay)
    }
}
