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
) {
    companion object {
        private const val TAG = "RelayImportService"
        private const val IMPORT_POLL_INTERVAL_MS = 300L
    }

    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Default)

    // ── Import state ─────────────────────────────────────────────

    private val _isImporting = MutableStateFlow(false)
    val isImporting: StateFlow<Boolean> = _isImporting.asStateFlow()

    private val _importProgress = MutableStateFlow(0f)
    val importProgress: StateFlow<Float> = _importProgress.asStateFlow()

    private val _importStatusMessage = MutableStateFlow("")
    val importStatusMessage: StateFlow<String> = _importStatusMessage.asStateFlow()

    private val _importCompleted = MutableStateFlow(false)
    val importCompleted: StateFlow<Boolean> = _importCompleted.asStateFlow()

    // ── Export state ─────────────────────────────────────────────

    private val _isExporting = MutableStateFlow(false)
    val isExporting: StateFlow<Boolean> = _isExporting.asStateFlow()

    private val _exportStatusMessage = MutableStateFlow("")
    val exportStatusMessage: StateFlow<String> = _exportStatusMessage.asStateFlow()

    private var importJob: Job? = null

    /**
     * Import notes from seed relays. Stops the running relay, starts it
     * in import mode, polls for progress, then restarts normally.
     */
    fun importNotes() {
        if (_isImporting.value || _isExporting.value) return
        if (configStore.config.value.useExternalRelay) {
            _importStatusMessage.value = EXTERNAL_RELAY_IMPORT_MESSAGE
            return
        }

        importJob = scope.launch {
            _isImporting.value = true
            _importProgress.value = 0f
            _importStatusMessage.value = "Preparing import..."
            _importCompleted.value = false

            try {
                // 1. Stop the running relay
                _importStatusMessage.value = "Stopping relay..."
                RelayForegroundService.stop(context)
                delay(2000) // Wait for service to fully stop

                // 2. Set up environment for import mode
                val config = configStore.config.value
                val relayDataDir = File(context.filesDir, "relay_data")
                RelayConfiguration.ensureDirectories(relayDataDir)
                val envDict = RelayConfiguration.generateEnvDictionary(config, relayDataDir)
                envDict.forEach { (key, value) ->
                    HavenBridge.setEnv(key, value)
                }

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

                _importProgress.value = 1f
                _importStatusMessage.value = "Import completed"
                _importCompleted.value = true
                Log.i(TAG, "Note import completed successfully")

            } catch (e: CancellationException) {
                _importStatusMessage.value = "Import cancelled"
                throw e
            } catch (e: Exception) {
                Log.e(TAG, "Import failed: ${e.message}", e)
                _importStatusMessage.value = "Import failed: ${e.message}"
            } finally {
                _isImporting.value = false
                // 4. Restart relay in normal mode
                _importStatusMessage.value = "Restarting relay..."
                delay(1000)
                RelayForegroundService.start(context)
            }
        }
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
        }
    }

    /**
     * Export relay database as a compressed JSONL zip backup.
     * @param outputPath absolute path for the output zip file
     */
    fun exportDatabase(outputPath: String) {
        if (_isImporting.value || _isExporting.value) return

        scope.launch {
            _isExporting.value = true
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
            }
        }
    }

    /**
     * Export Blossom media files as a zip archive.
     * @param outputPath absolute path for the output zip file
     */
    fun exportBlossom(outputPath: String) {
        if (_isImporting.value || _isExporting.value) return

        scope.launch {
            _isExporting.value = true
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
            }
        }
    }

    /**
     * Dismiss the import completed state so the progress section hides.
     */
    fun dismissImportProgress() {
        _importCompleted.value = false
        _importProgress.value = 0f
        _importStatusMessage.value = ""
    }

    /**
     * Dismiss the export status message.
     */
    fun dismissExportStatus() {
        _exportStatusMessage.value = ""
    }

    /** Whether any operation is active (import or export). */
    val isBusy: Boolean
        get() = _isImporting.value || _isExporting.value

    // ── Internal ─────────────────────────────────────────────────

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
            } catch (e: CancellationException) {
                throw e
            } catch (e: Exception) {
                Log.w(TAG, "Import poll error: ${e.message}")
            }
            delay(IMPORT_POLL_INTERVAL_MS)
        }
    }
}
