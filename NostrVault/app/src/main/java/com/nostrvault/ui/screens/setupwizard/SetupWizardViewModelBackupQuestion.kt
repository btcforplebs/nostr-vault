package com.nostrvault.ui.screens

import com.nostrvault.relay.HavenBridge
import com.nostrvault.relay.RelayConfiguration
import com.nostrvault.relay.RelayForegroundService
import java.io.File

/**
 * The owner-checked restore that setup's older import step (ImportNotesStep)
 * still uses. Setup's two questions no longer offer a backup zip: restoring
 * one lives in Settings › Backup & Restore. Same as iOS `VaultBackupQuestion`.
 */
object VaultBackupQuestion {
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
