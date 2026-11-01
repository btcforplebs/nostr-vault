package com.nostrvault.relay

import android.util.Log
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import javax.inject.Inject
import javax.inject.Singleton

/**
 * Singleton that polls every Go relay log line via HavenBridge.getLogLines()
 * and stores parsed LogEntry items for the dashboard console viewer. It also
 * applies what the lines say (boot status, inbox activity, lock and port
 * errors) and the relay's open connection count. iOS:
 * RelayProcessManager.captureOutput / applyBatchedUpdate.
 */
@Singleton
class LogStore @Inject constructor() {

    companion object {
        private const val TAG = "LogStore"
        private const val MAX_LOGS = 500
        private const val POLL_INTERVAL_MS = 200L
    }

    private val _logs = MutableStateFlow<List<RelayLogParser.LogEntry>>(emptyList())
    val logs: StateFlow<List<RelayLogParser.LogEntry>> = _logs.asStateFlow()

    /**
     * What the relay is doing while it boots ("Building trust network…"), for
     * the feed's Relay Starting screen; empty once it is listening. iOS
     * RelayProcessManager.bootStatusMessage.
     */
    private val _bootStatusMessage = MutableStateFlow("")
    val bootStatusMessage: StateFlow<String> = _bootStatusMessage.asStateFlow()

    private var pollingJob: Job? = null

    /**
     * Optional sink for raw `🔔NOTIFY|...` marker lines, set by the relay
     * foreground service so [com.nostrvault.service.LocalNotificationService] can
     * raise local system notifications. Kept as a plain callback so this store
     * stays dependency-free.
     */
    @Volatile
    var notifySink: ((String) -> Unit)? = null
    /**
     * The inbox kinds a poll's NOTIFY markers carried only as one of your
     * accounts tagging another, while that stays quiet: their import lines
     * light no Vault tab dot (AccountUnreadStore.ownAccountOnlyKinds).
     */
    var quietKinds: ((List<String>) -> Set<Int>)? = null

    fun addEntry(entry: RelayLogParser.LogEntry) {
        val current = _logs.value.toMutableList()
        current.add(entry)
        if (current.size > MAX_LOGS) {
            _logs.value = current.takeLast(MAX_LOGS)
        } else {
            _logs.value = current
        }
    }

    private fun addEntries(entries: List<RelayLogParser.LogEntry>) {
        if (entries.isEmpty()) return
        _logs.update { (it + entries).takeLast(MAX_LOGS) }
    }

    fun clear() {
        _logs.value = emptyList()
    }

    /**
     * Start polling the relay's log and connection count.
     * Should be called when the relay transitions to BOOTING or RUNNING.
     */
    fun startPolling(scope: CoroutineScope) {
        if (pollingJob?.isActive == true) return
        pollingJob = scope.launch {
            Log.d(TAG, "Log polling started")
            // Lines queued before this poller started belong to an earlier run
            // or to an import, whose own poller already showed them.
            withContext(Dispatchers.IO) { readLogLines() }
            while (isActive) {
                try {
                    val lines = withContext(Dispatchers.IO) { readLogLines() }
                    // Drain the dedicated, non-lossy notification queue first:
                    // its markers name each event's author, which the import
                    // lines below do not.
                    val sink = notifySink
                    val markers = ArrayList<String>()
                    if (sink != null && HavenBridge.isLoaded) {
                        while (isActive) {
                            val notifyLine = withContext(Dispatchers.IO) { HavenBridge.getNotifyLog() }
                            if (notifyLine.isNullOrBlank()) break
                            markers += notifyLine
                        }
                    }
                    if (lines.isNotEmpty()) {
                        val quiet = runCatching { quietKinds?.invoke(markers) }.getOrNull().orEmpty()
                        applyLines(lines, quiet)
                    }
                    if (HavenBridge.isLoaded) {
                        withContext(Dispatchers.IO) { readConnections() }
                            ?.let { RelayForegroundService.updateConnections(it) }
                    }

                    // Forward every marker to the local notifier.
                    if (sink != null) {
                        for (notifyLine in markers) {
                            try {
                                sink.invoke(notifyLine)
                            } catch (e: Exception) {
                                Log.w(TAG, "Notify dispatch error: ${e.message}")
                            }
                        }
                    }
                } catch (e: Exception) {
                    // Don't crash the polling loop on transient errors
                    Log.w(TAG, "Log poll error: ${e.message}")
                }
                delay(POLL_INTERVAL_MS)
            }
            Log.d(TAG, "Log polling stopped")
        }
    }

    /** Parse a batch of log lines, store them and apply the state they carry. */
    internal fun applyLines(lines: List<String>, quietKinds: Set<Int> = emptySet()) {
        val batch = RelayLogParser.BatchedStateUpdate()
        val entries = ArrayList<RelayLogParser.LogEntry>(lines.size)
        for (line in lines) {
            // Light the red dot only for inbound events from OTHERS. The
            // relay logs these phrases exclusively in its inbox/chat import
            // handler; your own posts/blasts never produce them. The kind
            // on the line says which Vault list the dot is for.
            if (line.contains("in your inbox") || line.contains("in your chat relay")) {
                val kind = RelayLogParser.inboxActivityKind(line)
                // One of your accounts tagging another, kept quiet: no dot.
                if (kind == null || kind !in quietKinds) RelayForegroundService.markInboxActivity(kind)
            }
            entries.add(RelayLogParser.LogEntry.parse(line))
            RelayLogParser.collectStateChanges(line, batch)
        }
        addEntries(entries)
        when {
            batch.stopBooting -> _bootStatusMessage.value = ""
            batch.bootStatusMessage != null -> _bootStatusMessage.value = batch.bootStatusMessage!!
        }
        if (batch.isLocked || batch.isPortConflict) {
            RelayForegroundService.updateErrorStates(
                locked = batch.isLocked || RelayForegroundService.isLocked.value,
                portConflict = batch.isPortConflict || RelayForegroundService.isPortConflict.value,
            )
        }
    }

    /**
     * Every line since the last read. Falls back to the latest-line-only
     * import log when libhaven.so predates getLogLines.
     */
    private fun readLogLines(): List<String> {
        if (!HavenBridge.isLoaded) return emptyList()
        val joined = if (hasFullLog) {
            try {
                HavenBridge.getLogLines().also {
                    // Keep emptying the latest-line log as before, so an import
                    // poller started later doesn't open on a stale line.
                    HavenBridge.getImportLog()
                }
            } catch (e: UnsatisfiedLinkError) {
                Log.w(TAG, "libhaven.so has no getLogLines; showing the latest line only")
                hasFullLog = false
                HavenBridge.getImportLog()
            }
        } else {
            HavenBridge.getImportLog()
        }
        if (joined.isNullOrBlank()) return emptyList()
        return joined.split('\n').filter { it.isNotBlank() }
    }

    private fun readConnections(): Int? {
        if (!hasConnectionCount) return null
        return try {
            HavenBridge.activeConnections()
        } catch (e: UnsatisfiedLinkError) {
            hasConnectionCount = false
            null
        }
    }

    @Volatile private var hasFullLog = true
    @Volatile private var hasConnectionCount = true

    /**
     * Stop polling. Should be called when the relay goes OFFLINE.
     */
    fun stopPolling() {
        pollingJob?.cancel()
        pollingJob = null
        RelayForegroundService.updateConnections(0)
    }
}
