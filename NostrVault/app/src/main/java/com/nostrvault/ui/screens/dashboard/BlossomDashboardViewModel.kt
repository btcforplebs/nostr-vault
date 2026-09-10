package com.nostrvault.ui.screens.dashboard

import android.util.Log
import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import com.nostrvault.data.local.ConfigStore
import com.nostrvault.service.BlossomService
import com.nostrvault.service.NostrService
import com.nostrvault.service.StatsService
import dagger.hilt.android.lifecycle.HiltViewModel
import kotlinx.coroutines.*
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import okhttp3.OkHttpClient
import okhttp3.Request
import javax.inject.Inject

@HiltViewModel
class BlossomDashboardViewModel @Inject constructor(
    private val blossomService: BlossomService,
    private val statsService: StatsService,
    private val configStore: ConfigStore,
    private val nostrService: NostrService,
) : ViewModel() {

    companion object {
        private const val TAG = "BlossomDashVM"
    }

    // ── Stats ─────────────────────────────────────────────────

    private val _totalFiles = MutableStateFlow(0)
    val totalFiles: StateFlow<Int> = _totalFiles.asStateFlow()

    private val _totalSize = MutableStateFlow(0L)
    val totalSize: StateFlow<Long> = _totalSize.asStateFlow()

    private val _isLoadingStats = MutableStateFlow(true)
    val isLoadingStats: StateFlow<Boolean> = _isLoadingStats.asStateFlow()

    // ── Mirrors ───────────────────────────────────────────────

    private val _mirrors = MutableStateFlow<List<MirrorInfo>>(emptyList())
    val mirrors: StateFlow<List<MirrorInfo>> = _mirrors.asStateFlow()

    // ── Sync operations ───────────────────────────────────────

    private val _isPulling = MutableStateFlow(false)
    val isPulling: StateFlow<Boolean> = _isPulling.asStateFlow()

    private val _isPushing = MutableStateFlow(false)
    val isPushing: StateFlow<Boolean> = _isPushing.asStateFlow()

    private val _syncMessage = MutableStateFlow("")
    val syncMessage: StateFlow<String> = _syncMessage.asStateFlow()

    // ── Activity logs ─────────────────────────────────────────

    private val _activityLogs = MutableStateFlow<List<BlossomActivityLog>>(emptyList())
    val activityLogs: StateFlow<List<BlossomActivityLog>> = _activityLogs.asStateFlow()

    private val remoteClient = OkHttpClient.Builder()
        .connectTimeout(10, java.util.concurrent.TimeUnit.SECONDS)
        .readTimeout(10, java.util.concurrent.TimeUnit.SECONDS)
        .build()

    init {
        loadDashboard()
    }

    fun loadDashboard() {
        viewModelScope.launch {
            _isLoadingStats.value = true

            // Load mirrors from config
            val config = configStore.config.value
            val mirrorUrls = config.activeBlossomMirrors
            _mirrors.value = mirrorUrls.map { MirrorInfo(url = it) }

            // Load blob stats
            try {
                val blobs = statsService.fetchBlobList(nostrService.ownerHexPubkey)
                _totalFiles.value = blobs.size
                _totalSize.value = blobs.sumOf { it.size ?: 0L }
            } catch (e: Exception) {
                Log.w(TAG, "Failed to load blob stats: ${e.message}")
            }

            _isLoadingStats.value = false

            // Health check mirrors in parallel
            checkMirrorHealth()
        }
    }

    fun checkMirrorHealth() {
        viewModelScope.launch {
            val currentMirrors = _mirrors.value.toList()
            val updatedMirrors = currentMirrors.map { mirror ->
                async(Dispatchers.IO) {
                    val start = System.currentTimeMillis()
                    try {
                        val request = Request.Builder().url(mirror.url).head().build()
                        val response = remoteClient.newCall(request).execute()
                        val elapsed = (System.currentTimeMillis() - start).toInt()
                        val healthy = response.code in 200..499
                        mirror.copy(isHealthy = healthy, responseTimeMs = elapsed)
                    } catch (e: Exception) {
                        mirror.copy(isHealthy = false, responseTimeMs = null)
                    }
                }
            }.awaitAll()
            _mirrors.value = updatedMirrors
        }
    }

    fun pullFromNotes() {
        if (_isPulling.value) return
        _isPulling.value = true
        _syncMessage.value = "Scanning notes for media..."
        addLog("Starting pull from notes...", BlossomActivityLog.LogLevel.INFO)

        viewModelScope.launch {
            try {
                val config = configStore.config.value
                val blobs = statsService.fetchBlobList(nostrService.ownerHexPubkey)
                val mirrorUrls = config.activeBlossomMirrors

                if (mirrorUrls.isEmpty()) {
                    addLog("No mirrors configured", BlossomActivityLog.LogLevel.WARNING)
                    _syncMessage.value = "No mirrors configured"
                    _isPulling.value = false
                    return@launch
                }

                addLog("${blobs.size} blobs local — scanning ${mirrorUrls.size} mirrors...", BlossomActivityLog.LogLevel.INFO)
                _syncMessage.value = "Scanning ${mirrorUrls.size} mirrors..."

                blossomService.mirrorAllFromExternal(
                    onProgress = { pct ->
                        _syncMessage.value = "Mirroring... ${(pct * 100).toInt()}%"
                    },
                    onLogMessage = { msg ->
                        addLog(msg, BlossomActivityLog.LogLevel.INFO)
                    },
                )

                addLog("Pull complete", BlossomActivityLog.LogLevel.SUCCESS)
                _syncMessage.value = "Pull complete"
                loadDashboard()
            } catch (e: Exception) {
                addLog("Pull failed: ${e.message}", BlossomActivityLog.LogLevel.ERROR)
                _syncMessage.value = "Pull failed"
            } finally {
                _isPulling.value = false
            }
        }
    }

    fun pushToMirrors() {
        if (_isPushing.value) return
        _isPushing.value = true
        _syncMessage.value = "Pushing to mirrors..."
        addLog("Starting push to mirrors...", BlossomActivityLog.LogLevel.INFO)

        viewModelScope.launch {
            try {
                val blobs = statsService.fetchBlobList(nostrService.ownerHexPubkey)
                var pushed = 0

                for (blob in blobs) {
                    val sha256 = blob.sha256 ?: continue
                    try {
                        blossomService.pushLocalToMirrors(sha256)
                        pushed++
                        if (pushed % 10 == 0) {
                            _syncMessage.value = "Pushed $pushed/${blobs.size}..."
                        }
                    } catch (e: Exception) {
                        addLog("Failed to push ${sha256.take(8)}: ${e.message}", BlossomActivityLog.LogLevel.WARNING)
                    }
                }

                addLog("Push complete: $pushed files synced", BlossomActivityLog.LogLevel.SUCCESS)
                _syncMessage.value = "Push complete: $pushed files"
            } catch (e: Exception) {
                addLog("Push failed: ${e.message}", BlossomActivityLog.LogLevel.ERROR)
                _syncMessage.value = "Push failed"
            } finally {
                _isPushing.value = false
            }
        }
    }

    private fun addLog(message: String, level: BlossomActivityLog.LogLevel) {
        val entry = BlossomActivityLog(message = message, level = level)
        val current = _activityLogs.value.toMutableList()
        current.add(entry)
        if (current.size > 100) {
            _activityLogs.value = current.takeLast(100)
        } else {
            _activityLogs.value = current
        }
    }
}
