package com.nostrvault.relay

import android.util.Log
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import javax.inject.Inject
import javax.inject.Singleton

/**
 * Singleton that polls Go relay logs via HavenBridge.getImportLog()
 * and stores parsed LogEntry items for the dashboard console viewer.
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

    private var pollingJob: Job? = null

    /**
     * Optional sink for raw `🔔NOTIFY|...` marker lines, set by the relay
     * foreground service so [com.nostrvault.service.LocalNotificationService] can
     * raise local system notifications. Kept as a plain callback so this store
     * stays dependency-free.
     */
    @Volatile
    var notifySink: ((String) -> Unit)? = null

    fun addEntry(entry: RelayLogParser.LogEntry) {
        val current = _logs.value.toMutableList()
        current.add(entry)
        if (current.size > MAX_LOGS) {
            _logs.value = current.takeLast(MAX_LOGS)
        } else {
            _logs.value = current
        }
    }

    fun clear() {
        _logs.value = emptyList()
    }

    /**
     * Start polling HavenBridge.getImportLog() for new log messages.
     * Should be called when the relay transitions to BOOTING or RUNNING.
     */
    fun startPolling(scope: CoroutineScope) {
        if (pollingJob?.isActive == true) return
        pollingJob = scope.launch {
            Log.d(TAG, "Log polling started")
            while (isActive) {
                try {
                    val message = withContext(Dispatchers.IO) {
                        if (HavenBridge.isLoaded) HavenBridge.getImportLog() else null
                    }
                    if (!message.isNullOrBlank()) {
                        // Light the red dot only for inbound events from OTHERS. The
                        // relay logs these phrases exclusively in its inbox/chat import
                        // handler; your own posts/blasts never produce them.
                        if (message.contains("in your inbox") || message.contains("in your chat relay")) {
                            RelayForegroundService.markInboxActivity()
                        }
                        val entry = RelayLogParser.LogEntry.parse(message)
                        addEntry(entry)
                    }

                    // Drain the dedicated, non-lossy notification queue and forward
                    // every marker to the local notifier. Unlike the import log above
                    // (latest-message-only), this delivers every inbound event.
                    val sink = notifySink
                    if (sink != null && HavenBridge.isLoaded) {
                        while (isActive) {
                            val notifyLine = withContext(Dispatchers.IO) { HavenBridge.getNotifyLog() }
                            if (notifyLine.isNullOrBlank()) break
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

    /**
     * Stop polling. Should be called when the relay goes OFFLINE.
     */
    fun stopPolling() {
        pollingJob?.cancel()
        pollingJob = null
    }
}
