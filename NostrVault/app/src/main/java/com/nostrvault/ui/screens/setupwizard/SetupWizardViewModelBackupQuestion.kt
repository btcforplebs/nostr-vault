package com.nostrvault.ui.screens

import android.net.Uri
import androidx.lifecycle.viewModelScope
import com.nostrvault.relay.HavenBridge
import com.nostrvault.relay.RelayConfiguration
import com.nostrvault.relay.RelayForegroundService
import com.nostrvault.tutorials.TutorialCenter
import com.nostrvault.tutorials.TutorialID
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import java.io.File

/**
 * Setup's "Do you have a Vault backup?" question for people who already use
 * Nostr, asked right after their key. Yes restores the backup file and
 * finishes setup, skipping the relay import, which would only fetch the same
 * notes again. No is the flow as it was: the relay check comes next. Same as
 * iOS `VaultBackupQuestion`.
 */
object VaultBackupQuestion {
    sealed interface State {
        data object Ask : State
        data object Restoring : State
        data object Restored : State
        data class Failed(val message: String) : State
    }

    /**
     * What setup's restore tells the person, from the relay's restore code
     * (RestoreOwnBackupC): null on success. Setup only restores a backup that
     * holds notes signed by the key signing in, so someone else's backup is
     * never merged into a new vault.
     */
    fun restoreError(code: Int): String? = when (code) {
        0 -> null
        2 -> "This backup isn't yours. It holds no notes signed by the key you signed in with."
        else -> "Failed to restore backup. Check logs for details."
    }
}

/** No backup: on to the relay check, as before. */
fun SetupWizardViewModel.answerNoBackup() {
    _backupQuestion.value = VaultBackupQuestion.State.Ask
    _step.value = stepAfter(WizardStep.BACKUP_QUESTION)
}

/** Yes: the picked file is copied where the relay can read it, then restored. */
fun SetupWizardViewModel.restoreBackupFromQuestion(uri: Uri) {
    if (_backupQuestion.value == VaultBackupQuestion.State.Restoring) return
    _backupQuestion.value = VaultBackupQuestion.State.Restoring
    viewModelScope.launch {
        val copy = withContext(Dispatchers.IO) {
            runCatching {
                val file = File(appContext.cacheDir, "setup_backup.zip")
                appContext.contentResolver.openInputStream(uri)!!.use { input ->
                    file.outputStream().use { output -> input.copyTo(output) }
                }
                file
            }.getOrNull()
        }
        if (copy == null) {
            _backupQuestion.value = VaultBackupQuestion.State.Failed("Couldn't read that file.")
            return@launch
        }
        restoreBackupFile(copy)
    }
}

/**
 * Restores [file] with [restore] (the owner-checked restore by default) and
 * deletes it after. Separate from the picker so tests can drive it.
 */
internal suspend fun SetupWizardViewModel.restoreBackupFile(
    file: File,
    restore: suspend (String) -> Int = { runOwnBackupRestore(it) },
) {
    _backupQuestion.value = VaultBackupQuestion.State.Restoring
    val code = withContext(Dispatchers.IO) {
        try { restore(file.absolutePath) } catch (_: Exception) { 1 } finally { file.delete() }
    }
    _backupQuestion.value = VaultBackupQuestion.restoreError(code)
        ?.let { VaultBackupQuestion.State.Failed(it) }
        ?: VaultBackupQuestion.State.Restored
}

/** "Continue" after a restore: setup is done, nothing left to import. */
fun SetupWizardViewModel.finishAfterBackupRestore(onComplete: () -> Unit) {
    if (_backupQuestion.value != VaultBackupQuestion.State.Restored) return
    // The import tour explains a relay import that never ran.
    val account = HavenBridge.decodeNpub(configStore.config.value.ownerNpub).orEmpty()
    TutorialCenter.skip(TutorialID.IMPORT_TOUR, account)
    completeSetup(onComplete)
}

fun SetupWizardViewModel.dismissBackupError() {
    if (_backupQuestion.value is VaultBackupQuestion.State.Failed) {
        _backupQuestion.value = VaultBackupQuestion.State.Ask
    }
}

/**
 * The owner-checked restore. The Go restore opens the databases itself, so a
 * running relay is stopped first and started again after; one that isn't
 * running stays down, with the relay's environment set so the restore knows
 * the owner. iOS `runOwnBackupRestore`.
 */
internal suspend fun SetupWizardViewModel.runOwnBackupRestore(zipPath: String): Int =
    if (RelayForegroundService.serviceAlive) {
        relayImportService.withRelayStopped { HavenBridge.restoreOwnBackup(zipPath) }
    } else {
        val relayDataDir = File(appContext.filesDir, "relay_data")
        RelayConfiguration.ensureDirectories(relayDataDir)
        RelayConfiguration.generateEnvDictionary(configStore.config.value, relayDataDir)
            .forEach { (key, value) -> HavenBridge.setEnv(key, value) }
        HavenBridge.restoreOwnBackup(zipPath)
    }
