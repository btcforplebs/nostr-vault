package com.nostrvault.ui.screens

import androidx.compose.animation.*
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.*
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.lifecycle.viewModelScope
import com.nostrvault.relay.BlossomArchive
import com.nostrvault.relay.HavenBridge
import com.nostrvault.relay.RelayConfiguration
import com.nostrvault.relay.RelayForegroundService
import com.nostrvault.service.ListMerge
import com.nostrvault.service.syncOwnerServerList
import com.nostrvault.ui.theme.*
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import java.io.File
import java.net.URL

    fun SetupWizardViewModel.startNetworkImport() {
        if (_isImporting.value) return
        viewModelScope.launch {
            // Persist the selected import start date to config
            configStore.update { it.copy(importStartDate = _importStartDate.value) }

            _isImporting.value = true
            _importProgress.value = -1f
            _importStatus.value = "Setting up import..."
            _importCompleted.value = false

            // Poll Go relay logs in the background so the UI shows progress
            val pollJob = launch(Dispatchers.Default) {
                while (true) {
                    try {
                        val logLine = HavenBridge.getImportLog()
                        if (logLine != null) {
                            _importStatus.value = logLine
                        }
                    } catch (_: Exception) { }
                    kotlinx.coroutines.delay(400)
                }
            }

            withContext(Dispatchers.IO) {
                try {
                    if (!HavenBridge.isLoaded) {
                        _importStatus.value = "Native library not loaded"
                        _isImporting.value = false
                        return@withContext
                    }

                    val relayDataDir = File(appContext.filesDir, "relay_data")
                    RelayConfiguration.ensureDirectories(relayDataDir)

                    val config = configStore.config.value
                    val envDict = RelayConfiguration.generateEnvDictionary(
                        config = config,
                        relayDataDir = relayDataDir,
                    )
                    for ((key, value) in envDict) {
                        HavenBridge.setEnv(key, value)
                    }

                    // Write seed relays JSON and set env to ABSOLUTE path
                    val seedRelaysFile = File(relayDataDir, "relays_import.json")
                    val seedRelays = config.importSeedRelays
                    val relaysJson = buildString {
                        append("[")
                        append(seedRelays.joinToString(",") { "\"$it\"" })
                        append("]")
                    }
                    seedRelaysFile.writeText(relaysJson)
                    HavenBridge.setEnv("IMPORT_SEED_RELAYS_FILE", seedRelaysFile.absolutePath)

                    // Also fix other file-based env vars that need absolute paths
                    val blastrFile = File(relayDataDir, config.blastrRelaysFile)
                    if (!blastrFile.exists()) {
                        val blastrJson = buildString {
                            append("[")
                            append(config.blastrRelays.joinToString(",") { "\"$it\"" })
                            append("]")
                        }
                        blastrFile.writeText(blastrJson)
                    }
                    HavenBridge.setEnv("BLASTR_RELAYS_FILE", blastrFile.absolutePath)

                    // Ensure import start date is set
                    val startDate = config.importStartDate.ifEmpty { "2023-01-01" }
                    HavenBridge.setEnv("IMPORT_START_DATE", startDate)

                    // startRelay(importMode = true) is blocking -- pollJob
                    // feeds Go log output to _importStatus while this runs
                    HavenBridge.startRelay(importMode = true)

                    _importCompleted.value = true
                    _importStatus.value = "Import complete"
                } catch (e: Exception) {
                    _importStatus.value = "Import failed: ${e.message}"
                }
                _isImporting.value = false
            }

            pollJob.cancel()
        }
    }

    fun SetupWizardViewModel.restoreFromBackup(zipPath: String) {
        if (_isImporting.value) return
        viewModelScope.launch {
            _isImporting.value = true
            _importStatus.value = "Restoring from backup..."
            _importCompleted.value = false

            withContext(Dispatchers.IO) {
                try {
                    // Setup only restores the signing-in key's own backup,
                    // same as the backup question (runOwnBackupRestore).
                    val result = runOwnBackupRestore(zipPath)
                    File(zipPath).delete()
                    if (result == 0) {
                        _importCompleted.value = true
                        _importStatus.value = "Restore complete"
                    } else {
                        _importStatus.value = VaultBackupQuestion.restoreError(result) ?: "Restore failed"
                    }
                } catch (e: Exception) {
                    _importStatus.value = "Restore failed: ${e.message}"
                }
                _isImporting.value = false
            }
        }
    }

    fun SetupWizardViewModel.cancelImport() {
        viewModelScope.launch(Dispatchers.IO) {
            try { HavenBridge.stopRelay() } catch (_: Exception) {}
        }
    }

    fun SetupWizardViewModel.advanceFromImport() {
        _step.value = if (_setupPath.value == SetupPath.BROWSE) WizardStep.COMPLETE else WizardStep.MIRROR_MEDIA
    }
    fun SetupWizardViewModel.skipImport() {
        _step.value = if (_setupPath.value == SetupPath.BROWSE) WizardStep.COMPLETE else WizardStep.MIRROR_MEDIA
    }

    // ── Blossom ──────────────────────────────────────────────────

    fun SetupWizardViewModel.startMediaMirror() {
        if (_isMirroring.value) return
        viewModelScope.launch {
            _isMirroring.value = true
            _mirrorProgress.value = -1f
            _mirrorStatus.value = "Starting media sync..."
            _mirrorCompleted.value = false

            // Their published media server list (kind 10063) first, in their
            // order. The suggested server is added only when they have none;
            // a server they typed goes after theirs.
            runCatching { nostrService.syncOwnerServerList() }
            val url = _blossomURL.value.trim()
            configStore.update { config ->
                SetupMirrorSource.mirrors(config.blossomMirrors, url)?.let { config.copy(blossomMirrors = it) } ?: config
            }

            try {
                blossomService.mirrorAllFromExternal(
                    onProgress = { progress ->
                        _mirrorProgress.value = progress
                    },
                    onLogMessage = { message ->
                        _mirrorStatus.value = message
                    },
                )
                _mirrorCompleted.value = true
                _mirrorStatus.value = "Media sync complete"
            } catch (e: Exception) {
                _mirrorStatus.value = "Sync failed: ${e.message}"
            }
            _isMirroring.value = false
        }
    }

    fun SetupWizardViewModel.importMediaArchive(zipPath: String) {
        if (_isMirroring.value) return
        viewModelScope.launch {
            _isMirroring.value = true
            _mirrorStatus.value = "Extracting media archive..."
            _mirrorCompleted.value = false

            withContext(Dispatchers.IO) {
                try {
                    val relayDataDir = File(appContext.filesDir, "relay_data")
                    val blossomDir = File(relayDataDir, "blossom")
                    blossomDir.mkdirs()
                    // Reads iOS and Android media backups alike.
                    val result = BlossomArchive.import(File(zipPath), blossomDir)
                    if (result.imported > 0 || result.skipped == 0) {
                        _mirrorCompleted.value = true
                        _mirrorStatus.value = "Media import complete"
                    } else {
                        _mirrorStatus.value = "Import failed: no media files in this backup"
                    }
                } catch (e: Exception) {
                    _mirrorStatus.value = "Import failed: ${e.message}"
                }
                _isMirroring.value = false
            }
        }
    }

    fun SetupWizardViewModel.advanceFromMedia() { _step.value = WizardStep.WALLET }
    fun SetupWizardViewModel.skipMedia() { _step.value = WizardStep.WALLET }

    // ── Wallet ───────────────────────────────────────────────────

    fun SetupWizardViewModel.advanceFromWallet() {
        val nwc = _nwcInput.value.trim().ifEmpty { null }
        configStore.update { it.copy(nwcURI = nwc) }
        _step.value = stepAfter(WizardStep.WALLET)
    }

    fun SetupWizardViewModel.skipWallet() { _step.value = stepAfter(WizardStep.WALLET) }

    // ── Notifications ("Stay in the Loop", iOS PushNotificationStep) ──

/** Suggested in setup's media step: a server to sync from. */
internal const val SUGGESTED_MIRROR_SOURCE = "https://blossom.primal.net"

/** What setup's media step does to the upload servers. Pure for the tests. */
internal object SetupMirrorSource {
    /**
     * The upload servers after syncing from [url], or null for no change.
     * [current] already holds the account's own published list when it has
     * one: the suggestion is then not added, so it never becomes a server
     * they did not pick. A server they typed is added after theirs.
     */
    fun mirrors(current: List<String>, url: String, suggested: String = SUGGESTED_MIRROR_SOURCE): List<String>? {
        val u = url.trim()
        if (u.isEmpty()) return null
        if (current.any { ListMerge.key(it) == ListMerge.key(u) }) return null
        if (current.isNotEmpty() && ListMerge.key(u) == ListMerge.key(suggested)) return null
        return current + u
    }
}
