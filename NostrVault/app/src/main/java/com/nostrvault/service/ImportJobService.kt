package com.nostrvault.service

import com.nostrvault.di.ApplicationScope
import com.nostrvault.relay.HavenBridge
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import javax.inject.Inject
import javax.inject.Singleton

/**
 * The relay's import jobs through JNI (ImportJobsC / RunImportJobC / CancelImportJobC, Ted #1763). Re-read on every
 * `IMPORT_JOB` log line ([onLogLine], fed by the relay service) and after each Run or Cancel. The relay keeps serving
 * while a job runs: no import mode, no stopped vault.
 */
@Singleton
class ImportJobService @Inject constructor(
    @ApplicationScope private val scope: CoroutineScope,
) {
    private val _jobs = MutableStateFlow<ImportJobs?>(null)
    /** The last list read; null before the relay answered once. */
    val jobs: StateFlow<ImportJobs?> = _jobs.asStateFlow()

    /** Reads the list now (off the main thread) and returns it. */
    suspend fun read(): ImportJobs? = withContext(Dispatchers.IO) {
        if (!HavenBridge.isLoaded) return@withContext null
        ImportJobs.parse(runCatching { HavenBridge.importJobs() }.getOrNull())
    }?.also { _jobs.value = it }

    fun refresh() {
        scope.launch { read() }
    }

    /** A relay log line: an `IMPORT_JOB` status change re-reads the list. */
    fun onLogLine(raw: String) {
        if (raw.contains(ImportJobs.LOG_MARKER) && ImportJobs.logLine(raw) != null) refresh()
    }

    /** RunImportJobC (see [ImportJobs.RUN_STARTED] and the rest). */
    suspend fun run(name: String): Int = withContext(Dispatchers.IO) {
        if (!HavenBridge.isLoaded) ImportJobs.RUN_RELAY_NOT_RUNNING
        else runCatching { HavenBridge.runImportJob(name) }.getOrDefault(ImportJobs.RUN_RELAY_NOT_RUNNING)
    }.also { refresh() }

    /** CancelImportJobC: 0 cancelling · 1 not running. */
    suspend fun cancel(name: String): Int = withContext(Dispatchers.IO) {
        if (!HavenBridge.isLoaded) 1 else runCatching { HavenBridge.cancelImportJob(name) }.getOrDefault(1)
    }.also { refresh() }
}
