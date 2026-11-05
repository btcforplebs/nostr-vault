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
import org.junit.Assert.assertNull
import org.junit.Before
import org.junit.Test

/** Setup as two questions (PLANS/NV_FIRST_RUN_ENTRY_PLAN_2026_11_05.md): New to Nostr? then New to Nostr Vault? */
@OptIn(ExperimentalCoroutinesApi::class)
class SetupWizardNewToVaultTest {

    private var saved = HavenConfig()
    private lateinit var viewModel: SetupWizardViewModel

    @Before
    fun setUp() {
        Dispatchers.setMain(UnconfinedTestDispatcher())
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
            nostrService = mockk(relaxed = true),
            relayImportService = mockk(relaxed = true),
            statsService = mockk(relaxed = true),
            appContext = mockk(relaxed = true),
        )
        viewModel.choosePath(SetupPath.USE_NOSTR)
    }

    @After
    fun tearDown() = Dispatchers.resetMain()

    @Test
    fun `the second question comes right after your key and before the relay check`() {
        val steps = viewModel.activeSteps
        val question = steps.indexOf(WizardStep.NEW_TO_VAULT)
        assertEquals(steps.indexOf(WizardStep.USE_NOSTR_KEY) + 1, question)
        assertEquals(steps.indexOf(WizardStep.RELAY_CHECK) - 1, question)
    }

    @Test
    fun `I already use Nostr is never asked who told you`() {
        assertFalse(WizardStep.REFERRER in viewModel.activeSteps)
    }

    @Test
    fun `new accounts are never asked the second question`() {
        viewModel.choosePath(SetupPath.NEW_TO_NOSTR)
        assertFalse(WizardStep.NEW_TO_VAULT in viewModel.activeSteps)
    }

    @Test
    fun `an external relay is never asked, there is no vault to fill`() {
        viewModel.setUseExternalRelay(true)
        assertFalse(WizardStep.NEW_TO_VAULT in viewModel.activeSteps)
    }

    @Test
    fun `Yes, new to Nostr Vault, goes on to the relay check and Back returns to the question`() {
        viewModel.bringNotesFromRelays()
        assertEquals(WizardStep.RELAY_CHECK, viewModel.step.value)
        viewModel.goBack()
        assertEquals(WizardStep.NEW_TO_VAULT, viewModel.step.value)
    }

    @Test
    fun `I already use Nostr, read-only, still gets the second question and no Who told you`() {
        viewModel.advanceFromRelayChoice()
        viewModel.setUseNostrInput("nostr:npub1sg6plzptd64u62a878hep2kev88swjh3tw00gjsfl8f237lmu63q0uf63m")
        viewModel.continueUseNostr()
        assertEquals(WizardStep.NEW_TO_VAULT, viewModel.step.value)
        assertFalse(WizardStep.REFERRER in viewModel.activeSteps)
    }

    @Test
    fun `New to Nostr keeps Who told you, right after the profile`() {
        viewModel.choosePath(SetupPath.NEW_TO_NOSTR)
        val steps = viewModel.activeSteps
        assertEquals(steps.indexOf(WizardStep.PROFILE) + 1, steps.indexOf(WizardStep.REFERRER))
    }

    @Test
    fun `the question has just two answers and no backup or mesh words`() {
        assertEquals("New to Nostr Vault?", NewToVault.TITLE)
        assertEquals("Yes, bring my notes from relays", NewToVault.YES)
        assertEquals("No, copy from my other vault", NewToVault.NO)
        for (w in listOf(NewToVault.TITLE, NewToVault.BODY, NewToVault.YES, NewToVault.NO, BringItOver.LOST_DEVICE)) {
            for (banned in listOf("backup", "zip", "mesh", "fips", "npub", "address")) {
                assertFalse("\"$banned\" in: $w", w.lowercase().contains(banned))
            }
        }
    }

    @Test
    fun `restore codes map to the iOS messages`() {
        assertNull(VaultBackupQuestion.restoreError(0))
        assertEquals(
            "This backup isn't yours. It holds no notes signed by the key you signed in with.",
            VaultBackupQuestion.restoreError(2),
        )
        assertEquals("Failed to restore backup. Check logs for details.", VaultBackupQuestion.restoreError(1))
    }
}
