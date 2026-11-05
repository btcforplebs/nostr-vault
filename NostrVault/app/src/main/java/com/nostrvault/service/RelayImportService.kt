package com.nostrvault.service

import android.content.Context
import android.util.Log
import com.nostrvault.data.local.ConfigStore
import com.nostrvault.relay.HavenBridge
import com.nostrvault.relay.LogStore
import com.nostrvault.relay.RelayConfiguration
import com.nostrvault.relay.RelayForegroundService
import com.nostrvault.relay.RelayLogParser
import dagger.hilt.android.qualifiers.ApplicationContext
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import java.io.File
import javax.inject.Inject
import javax.inject.Singleton

/**
 * Orchestrates relay import/export operations, coordinating with
 * RelayForegroundService lifecycle and HavenBridge Go functions.
 *
 * Import flow: stop relay -> set env -> start in import mode -> poll progress -> restart relay
 * Export flow: call HavenBridge.backupDatabase() or zipDirectory() on IO dispatcher
 */
/** Import writes into the built-in relay's database, which is off in external mode. */
const val EXTERNAL_RELAY_IMPORT_MESSAGE =
    "Import fills the built-in relay, which is off while you use an external relay."

@Singleton
class RelayImportService @Inject constructor(
    @ApplicationContext private val context: Context,
    private val configStore: ConfigStore,
    private val logStore: LogStore,
    /** "Last ran" times for the Vault Dashboard (iOS VaultHistory). */
    private val vaultHistory: com.nostrvault.data.local.VaultHistoryStore,
) {
    companion object {
        private const val TAG = "RelayImportService"
        private const val IMPORT_POLL_INTERVAL_MS = 300L
        /** [withRelayStopped]'s answer when the vault is busy: nothing was stopped or run. */
        const val BUSY_CODE = -2
        const val BUSY_LINE = "The vault is busy importing. Try again when it ends."
    }

    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Default)

    // ── Import state ─────────────────────────────────────────────

    private val _isImporting = MutableStateFlow(false)
    val isImporting: StateFlow<Boolean> = _isImporting.asStateFlow()

    private val _importProgress = MutableStateFlow(0f)
    val importProgress: StateFlow<Float> = _importProgress.asStateFlow()

    private val _importStatusMessage = MutableStateFlow("")
    val importStatusMessage: StateFlow<String> = _importStatusMessage.asStateFlow()

    /** True only after an import that haven-go called complete ([ImportResult]); partial, failed and cancelled are not. */
    private val _importCompleted = MutableStateFlow(false)
    val importCompleted: StateFlow<Boolean> = _importCompleted.asStateFlow()

    /** How the last import ended, from haven-go's IMPORT_RESULT line; null while one runs or before any. */
    private val _importOutcome = MutableStateFlow<ImportResult?>(null)
    val importOutcome: StateFlow<ImportResult?> = _importOutcome.asStateFlow()

    /**
     * The one busy flag (twin of iOS busyJob, #1720): an import, export, backup or restore owns the databases. While
     * it is set, a restore, backup, stop, force-clean or a second import (a copy included) is refused.
     */
    private val _vaultOp = MutableStateFlow(false)
    val busy: StateFlow<Boolean> get() = _busy
    private val _busy = MutableStateFlow(false)
    private fun updateBusy() { _busy.value = _isImporting.value || _isExporting.value || _vaultOp.value }

    /** Moving in is looking for older list versions ([ListHistoryScan]); Skip shows meanwhile. */
    private val _listHistoryScanning = MutableStateFlow(false)
    val listHistoryScanning: StateFlow<Boolean> = _listHistoryScanning.asStateFlow()

    /** That scan's plain count, shown when it ends; null when it didn't run. */
    private val _listHistoryNote = MutableStateFlow<String?>(null)
    val listHistoryNote: StateFlow<String?> = _listHistoryNote.asStateFlow()

    // ── Export state ─────────────────────────────────────────────

    private val _isExporting = MutableStateFlow(false)
    val isExporting: StateFlow<Boolean> = _isExporting.asStateFlow()

    private val _exportStatusMessage = MutableStateFlow("")
    val exportStatusMessage: StateFlow<String> = _exportStatusMessage.asStateFlow()

    private var importJob: Job? = null

    /** Set when the relay couldn't be restarted after an import (the app was
     *  in the background). MainActivity starts it on the next foreground. */
    @Volatile private var relayRestartPending = false

    /** True once if the relay still needs the restart an import couldn't do. */
    fun takeRelayRestartPending(): Boolean = relayRestartPending.also { relayRestartPending = false }

    /**
     * Import notes from seed relays. Stops the running relay, starts it
     * in import mode, polls for progress, then restarts normally.
     * [listHistory]: "Look up and back up my lists" is on ([ListHistoryScan];
     * on by default, off skips every history relay).
     */
    fun importNotes(listHistory: Boolean = false, alsoFrom: List<String> = emptyList(), otherVault: String? = null): Boolean {
        // One busy flag: a second import (a copy's extra relays included) never joins or replaces a running one.
        if (isBusy) {
            Log.w(TAG, "Import refused: the vault is busy")
            return false
        }
        if (configStore.config.value.useExternalRelay) {
            _importStatusMessage.value = EXTERNAL_RELAY_IMPORT_MESSAGE
            return false
        }

        _isImporting.value = true
        updateBusy()
        _importOutcome.value = null
        importJob = scope.launch {
            var outcome: ImportResult = ImportResult.APP_FAILED
            _importProgress.value = 0f
            _importStatusMessage.value = "Preparing import..."
            _importCompleted.value = false
            _listHistoryScanning.value = false
            _listHistoryNote.value = null
            scanSkipped = false
            // Keeps the process alive if the app goes to the background.
            ImportForegroundService.start(context)

            try {
                // 1. Stop the running relay
                _importStatusMessage.value = "Stopping relay..."
                RelayForegroundService.stop(context)
                delay(2000) // Wait for service to fully stop

                // 2. Set up environment for import mode
                val config = configStore.config.value
                val relayDataDir = File(context.filesDir, "relay_data")
                RelayConfiguration.ensureDirectories(relayDataDir)
                val launched = RelayConfiguration.launchInputs(config, relayDataDir)
                // A copy's other vault reads as one more seed relay for this import only.
                val inputs = if (alsoFrom.isEmpty()) launched
                else launched.copy(importSeedRelays = (launched.importSeedRelays + alsoFrom).distinct())
                inputs.env.forEach { (key, value) ->
                    HavenBridge.setEnv(key, value)
                }
                // Always set: Go keeps the process environment between imports (import_result.go).
                HavenBridge.setEnv(ImportResult.OTHER_VAULT_ENV, otherVault.orEmpty())
                // Always set: Go keeps the process environment between imports.
                HavenBridge.setEnv(ListHistoryScan.OPT_IN_ENV, if (listHistory) "1" else "0")
                // Only the account moving in: never the device's other accounts.
                HavenBridge.setEnv(ListHistoryScan.ACCOUNT_ENV, if (listHistory) configStore.activeAccountHexPubkey.value else "")
                // The env above names the relay lists by bare filename, which
                // Go can't open from the app's working directory, and on a
                // first-run import (setup) the files don't exist yet.
                RelayConfiguration.writeRelayListFiles(config, inputs, relayDataDir)

                // 3. Start relay in import mode on IO thread
                _importStatusMessage.value = "Importing notes from seed relays..."
                logStore.clear()

                withContext(Dispatchers.IO) {
                    // Start polling for progress in parallel
                    val pollJob = launch {
                        pollImportProgress()
                    }

                    // This blocks until import completes
                    HavenBridge.startRelay(importMode = true)

                    pollJob.cancel()
                }
                pollListHistoryScan()

                // Only haven-go's result line may call it done (#1720 twin).
                outcome = ImportResult.parse(withContext(Dispatchers.IO) { runCatching { HavenBridge.getImportResult() }.getOrNull() })
                    ?: ImportResult.NO_RESULT
                if (outcome.isComplete) {
                    _importProgress.value = 1f
                    vaultHistory.record(com.nostrvault.data.local.VaultHistory.Entry.NOTES_IMPORT)
                }
                Log.i(TAG, "Import ended: ${outcome.status} ${outcome.reasons}")

            } catch (e: CancellationException) {
                outcome = ImportResult.CANCELLED
                throw e
            } catch (e: Exception) {
                Log.e(TAG, "Import failed: ${e.message}", e)
                outcome = ImportResult.APP_FAILED
            } finally {
                _importOutcome.value = outcome
                _importCompleted.value = outcome.isComplete
                _importStatusMessage.value = outcome.summary
                _isImporting.value = false
                updateBusy()
                _listHistoryScanning.value = false
                ImportForegroundService.stop(context)
                // 4. Restart relay in normal mode
                delay(1000)
                // Setup's import tour can leave the app before a long import
                // ends, and a foreground service can't be started from the
                // background (Android 12+). The relay then starts when the
                // app is next in the foreground rather than taking it down.
                runCatching { RelayForegroundService.start(context) }
                    .onFailure {
                        Log.w(TAG, "Relay restart after import failed: ${it.message}")
                        relayRestartPending = true
                    }
            }
        }
        return true
    }

    /**
     * Run an exclusive-DB Go operation (backup/restore) with the relay stopped,
     * then restart it — mirrors iOS RelayProcessManager.runBackupExport and the
     * importNotes() lifecycle above.
     *
     * The embedded relay holds the Badger/LMDB databases open in-process, so any
     * op that calls initDBs() (HavenBridge.backupDatabase / restoreDatabase) MUST
     * run while the relay is down, otherwise initDBs() can't acquire the DB and
     * the op returns a non-zero code. The relay status flips to OFFLINE before
     * StopRelayC -> CloseDBs() actually finishes, so we can't poll it; we wait a
     * conservative interval (shutdown is bounded to SHUTDOWN_TIMEOUT_MS = 5s) and
     * retry once if the DB is still locked.
     *
     * @param onStatus progress callback ("Stopping relay…", "Restarting relay…").
     * @param op the Go bridge call; returns 0 on success.
     * @return the op's return code (0 = success).
     */
    suspend fun withRelayStopped(onStatus: (String) -> Unit = {}, op: () -> Int): Int {
        // One busy flag: a restore or backup never runs under an import (or another of these).
        if (isBusy) {
            onStatus(BUSY_LINE)
            return BUSY_CODE
        }
        _vaultOp.value = true
        updateBusy()
        onStatus("Stopping relay…")
        RelayForegroundService.stop(context)

        // Re-apply env so the Go op's loadConfig()/initDBs() see the right DB paths.
        val config = configStore.config.value
        val relayDataDir = File(context.filesDir, "relay_data")
        RelayConfiguration.ensureDirectories(relayDataDir)
        RelayConfiguration.generateEnvDictionary(config, relayDataDir).forEach { (key, value) ->
            HavenBridge.setEnv(key, value)
        }

        return try {
            withContext(Dispatchers.IO) {
                delay(2500) // let onDestroy -> StopRelayC -> CloseDBs() finish
                var code = op()
                if (code != 0) {
                    // DB may still be closing on a slow shutdown; wait and retry once.
                    delay(2500)
                    code = op()
                }
                code
            }
        } finally {
            onStatus("Restarting relay…")
            delay(500)
            RelayForegroundService.start(context)
            _vaultOp.value = false
            updateBusy()
        }
    }

    /**
     * Export relay database as a compressed JSONL zip backup.
     * @param outputPath absolute path for the output zip file
     */
    fun exportDatabase(outputPath: String) {
        if (isBusy) return
        _isExporting.value = true
        updateBusy()
        scope.launch {
            _exportStatusMessage.value = "Exporting database..."

            try {
                val result = withContext(Dispatchers.IO) {
                    HavenBridge.backupDatabase(outputPath)
                }

                if (result == 0) {
                    _exportStatusMessage.value = "Database exported successfully"
                    Log.i(TAG, "Database export completed: $outputPath")
                } else {
                    _exportStatusMessage.value = "Database export failed"
                    Log.e(TAG, "Database export failed with code: $result")
                }
            } catch (e: Exception) {
                Log.e(TAG, "Database export error: ${e.message}", e)
                _exportStatusMessage.value = "Export error: ${e.message}"
            } finally {
                _isExporting.value = false
                updateBusy()
            }
        }
    }

    /**
     * Export Blossom media files as a zip archive.
     * @param outputPath absolute path for the output zip file
     */
    fun exportBlossom(outputPath: String) {
        if (isBusy) return
        _isExporting.value = true
        updateBusy()
        scope.launch {
            _exportStatusMessage.value = "Exporting media files..."

            try {
                val config = configStore.config.value
                val relayDataDir = File(context.filesDir, "relay_data")
                val blossomDir = File(relayDataDir, "blossom").absolutePath

                val result = withContext(Dispatchers.IO) {
                    HavenBridge.zipDirectory(blossomDir, outputPath)
                }

                if (result == 0) {
                    _exportStatusMessage.value = "Media exported successfully"
                    Log.i(TAG, "Blossom export completed: $outputPath")
                } else {
                    _exportStatusMessage.value = "Media export failed"
                    Log.e(TAG, "Blossom export failed with code: $result")
                }
            } catch (e: Exception) {
                Log.e(TAG, "Blossom export error: ${e.message}", e)
                _exportStatusMessage.value = "Export error: ${e.message}"
            } finally {
                _isExporting.value = false
                updateBusy()
            }
        }
    }

    /**
     * Dismiss the import completed state so the progress section hides.
     */
    fun dismissImportProgress() {
        _importCompleted.value = false
        _importOutcome.value = null
        _importProgress.value = 0f
        _importStatusMessage.value = ""
    }

    /**
     * Dismiss the export status message.
     */
    fun dismissExportStatus() {
        _exportStatusMessage.value = ""
    }

    /** Whether any operation owns the vault (import, export, backup or restore): the one busy flag. */
    val isBusy: Boolean
        get() = _isImporting.value || _isExporting.value || _vaultOp.value

    // ── Internal ─────────────────────────────────────────────────

    /** Moving in's Skip: stop the list history scan, keep what it found; the import carries on. */
    @Volatile private var scanSkipped = false

    fun skipListHistoryScan() {
        scanSkipped = true
        _listHistoryScanning.value = false
        scope.launch(Dispatchers.IO) { runCatching { HavenBridge.skipListHistoryScan() } }
    }

    /** The import log keeps only the latest line, so the scan's state is asked for directly. */
    private suspend fun pollListHistoryScan() {
        val raw = withContext(Dispatchers.IO) {
            if (HavenBridge.isLoaded) runCatching { HavenBridge.listHistoryScanStatus() }.getOrNull() else null
        }
        when (val s = ListHistoryScan.status(raw)) {
            ListHistoryScan.Status.None -> Unit
            ListHistoryScan.Status.Running -> {
                if (!scanSkipped) _listHistoryScanning.value = true
                _importStatusMessage.value = ListHistoryScan.LOOKING
            }
            is ListHistoryScan.Status.Done -> {
                _listHistoryScanning.value = false
                _listHistoryNote.value = ListHistoryScan.note(s.line)
                // The notes come next: say so, rather than leaving the scan's line up.
                if (_importStatusMessage.value == ListHistoryScan.LOOKING) _importStatusMessage.value = ListHistoryScan.NOTES_NEXT
            }
        }
    }

    private suspend fun pollImportProgress() {
        while (true) {
            try {
                val message = withContext(Dispatchers.IO) {
                    if (HavenBridge.isLoaded) HavenBridge.getImportLog() else null
                }
                if (!message.isNullOrBlank()) {
                    val entry = RelayLogParser.LogEntry.parse(message)
                    logStore.addEntry(entry)

                    // Extract progress from log messages
                    val batch = RelayLogParser.BatchedStateUpdate()
                    RelayLogParser.collectStateChanges(message, batch)

                    val progress = batch.importProgress
                    if (progress != null && progress > 0.0) {
                        _importProgress.value = progress.toFloat()
                    }
                    val statusMsg = batch.importStatusMessage
                    if (!statusMsg.isNullOrBlank()) {
                        _importStatusMessage.value = statusMsg
                    }
                }
                pollListHistoryScan()
            } catch (e: CancellationException) {
                throw e
            } catch (e: Exception) {
                Log.w(TAG, "Import poll error: ${e.message}")
            }
            delay(IMPORT_POLL_INTERVAL_MS)
        }
    }
}
