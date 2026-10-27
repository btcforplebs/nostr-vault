package com.nostrvault.ui.screens

import com.nostrvault.data.local.ConfigStore
import com.nostrvault.relay.HavenConfig
import io.mockk.every
import io.mockk.mockk
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.test.UnconfinedTestDispatcher
import kotlinx.coroutines.test.resetMain
import kotlinx.coroutines.test.runTest
import kotlinx.coroutines.test.setMain
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test
import java.io.File

/** "Do you have a Vault backup?" for people who already use Nostr (3.0.1 #10). */
@OptIn(ExperimentalCoroutinesApi::class)
class SetupWizardBackupQuestionTest {

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

    private fun backupFile() = File.createTempFile("backup", ".zip").apply { writeText("zip") }

    @Test
    fun `the question comes after your key and Who told you, and before the relay check`() {
        val steps = viewModel.activeSteps
        val question = steps.indexOf(WizardStep.BACKUP_QUESTION)
        assertEquals(steps.indexOf(WizardStep.USE_NOSTR_KEY) + 1, steps.indexOf(WizardStep.REFERRER))
        assertEquals(steps.indexOf(WizardStep.REFERRER) + 1, question)
        assertEquals(steps.indexOf(WizardStep.RELAY_CHECK) - 1, question)
    }

    @Test
    fun `new accounts are never asked`() {
        viewModel.choosePath(SetupPath.NEW_TO_NOSTR)
        assertFalse(WizardStep.BACKUP_QUESTION in viewModel.activeSteps)
    }

    @Test
    fun `an external relay is never asked, there is no vault to restore into`() {
        viewModel.setUseExternalRelay(true)
        assertFalse(WizardStep.BACKUP_QUESTION in viewModel.activeSteps)
    }

    @Test
    fun `No goes on to the relay check as before`() {
        viewModel.answerNoBackup()
        assertEquals(WizardStep.RELAY_CHECK, viewModel.step.value)
    }

    @Test
    fun `Back from the relay check returns to the question`() {
        viewModel.answerNoBackup()
        viewModel.goBack()
        assertEquals(WizardStep.BACKUP_QUESTION, viewModel.step.value)
    }

    @Test
    fun `a restored backup skips the relay check and deletes the copy`() = runTest {
        viewModel.answerNoBackup(); viewModel.goBack() // on the question
        val file = backupFile()
        var restoredPath: String? = null
        viewModel.restoreBackupFile(file) { restoredPath = it; 0 }
        assertEquals(file.absolutePath, restoredPath)
        assertEquals(VaultBackupQuestion.State.Restored, viewModel.backupQuestion.value)
        assertEquals(WizardStep.BACKUP_QUESTION, viewModel.step.value)
        assertFalse(file.exists())
    }

    @Test
    fun `someone else's backup is refused and nothing moves on`() = runTest {
        viewModel.answerNoBackup(); viewModel.goBack()
        val file = backupFile()
        viewModel.restoreBackupFile(file) { 2 }
        val state = viewModel.backupQuestion.value as VaultBackupQuestion.State.Failed
        assertTrue(state.message.startsWith("This backup isn't yours"))
        assertEquals(WizardStep.BACKUP_QUESTION, viewModel.step.value)
        assertFalse(file.exists())

        // Continue can't finish setup off a refused backup.
        var completed = false
        viewModel.finishAfterBackupRestore { completed = true }
        assertFalse(completed)
        assertFalse(saved.hasCompletedSetup)

        viewModel.dismissBackupError()
        assertEquals(VaultBackupQuestion.State.Ask, viewModel.backupQuestion.value)
    }

    @Test
    fun `a failed restore or a thrown one says so`() = runTest {
        viewModel.restoreBackupFile(backupFile()) { 1 }
        assertTrue(viewModel.backupQuestion.value is VaultBackupQuestion.State.Failed)
        viewModel.restoreBackupFile(backupFile()) { throw IllegalStateException("boom") }
        assertTrue(viewModel.backupQuestion.value is VaultBackupQuestion.State.Failed)
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

    @Test
    fun `starting over forgets an earlier answer`() = runTest {
        viewModel.restoreBackupFile(backupFile()) { 0 }
        viewModel.choosePath(SetupPath.USE_NOSTR)
        assertEquals(VaultBackupQuestion.State.Ask, viewModel.backupQuestion.value)
    }
}
