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

    /** Number of local blobs present on every reachable mirror (fully backed up). */
    private val _backedUpCount = MutableStateFlow(0)
    val backedUpCount: StateFlow<Int> = _backedUpCount.asStateFlow()

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

    /** Progress of the active pull/push, 0f..1f. */
    private val _syncProgress = MutableStateFlow(0f)
    val syncProgress: StateFlow<Float> = _syncProgress.asStateFlow()

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
            var localBlobs = emptyList<com.nostrvault.service.BlobDescriptor>()
            try {
                localBlobs = statsService.fetchBlobList(nostrService.ownerHexPubkey)
                _totalFiles.value = localBlobs.size
                _totalSize.value = localBlobs.sumOf { it.size ?: 0L }
            } catch (e: Exception) {
                Log.w(TAG, "Failed to load blob stats: ${e.message}")
            }

            _isLoadingStats.value = false

            // Health check mirrors in parallel
            checkMirrorHealth()

            // Compute backup coverage in the background (one /list call per mirror)
            computeBackedUpCount(localBlobs, mirrorUrls)
        }
    }

    /**
     * Each reachable mirror's full blob-hash set for [pubkey], one `/list/<pubkey>`
     * request per mirror (not per blob). A mirror that fails to respond is
     * excluded from the result rather than treated as missing every blob, so a
     * transient outage doesn't make everything look unbacked-up.
     */
    private suspend fun fetchMirrorHashSets(pubkey: String, mirrorUrls: List<String>): List<Set<String>> =
        mirrorUrls.map { mirror ->
            viewModelScope.async(Dispatchers.IO) {
                try {
                    statsService.fetchBlobList(pubkey, mirror)
                        .mapNotNull { it.sha256?.lowercase() }
                        .toSet()
                } catch (e: Exception) {
                    null // unreachable — exclude from the "all mirrors" check
                }
            }
        }.awaitAll().filterNotNull()

    /**
     * A blob counts as backed up when it is present on every reachable mirror.
     */
    private suspend fun computeBackedUpCount(
        localBlobs: List<com.nostrvault.service.BlobDescriptor>,
        mirrorUrls: List<String>,
    ) {
        if (localBlobs.isEmpty() || mirrorUrls.isEmpty()) {
            _backedUpCount.value = 0
            return
        }

        val mirrorHashSets = fetchMirrorHashSets(nostrService.ownerHexPubkey, mirrorUrls)
        if (mirrorHashSets.isEmpty()) {
            _backedUpCount.value = 0
            return
        }

        val localHashes = localBlobs.mapNotNull { it.sha256?.lowercase() }
        _backedUpCount.value = localHashes.count { hash -> mirrorHashSets.all { hash in it } }
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
        _syncProgress.value = 0f
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
                        _syncProgress.value = pct
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
        _syncProgress.value = 0f
        _syncMessage.value = "Checking mirror status..."
        addLog("Starting push to mirrors...", BlossomActivityLog.LogLevel.INFO)

        viewModelScope.launch {
            try {
                val config = configStore.config.value
                val mirrorUrls = config.activeBlossomMirrors
                if (mirrorUrls.isEmpty()) {
                    addLog("No mirrors configured", BlossomActivityLog.LogLevel.WARNING)
                    _syncMessage.value = "No mirrors configured"
                    return@launch
                }

                val blobs = statsService.fetchBlobList(nostrService.ownerHexPubkey)
                if (blobs.isEmpty()) {
                    addLog("No local files to back up", BlossomActivityLog.LogLevel.INFO)
                    _syncMessage.value = "No local files to back up"
                    return@launch
                }

                // Only push blobs missing from at least one reachable mirror — a
                // /list call per mirror is far cheaper than re-uploading blobs that
                // are already there. If every mirror fails to list (hashSets empty),
                // we can't tell what's missing, so fall back to pushing everything.
                val mirrorHashSets = fetchMirrorHashSets(nostrService.ownerHexPubkey, mirrorUrls)
                val needsPush = if (mirrorHashSets.isEmpty()) {
                    blobs
                } else {
                    blobs.filter { blob ->
                        val hash = blob.sha256?.lowercase()
                        hash == null || mirrorHashSets.any { hash !in it }
                    }
                }

                if (needsPush.isEmpty()) {
                    addLog("All files already backed up", BlossomActivityLog.LogLevel.SUCCESS)
                    _syncMessage.value = "All files already backed up"
                    _backedUpCount.value = blobs.size
                    return@launch
                }

                addLog("Pushing ${needsPush.size} file(s) to mirrors", BlossomActivityLog.LogLevel.INFO)
                _syncMessage.value = "Pushing ${needsPush.size} file(s)..."

                var pushed = 0
                for ((index, blob) in needsPush.withIndex()) {
                    val sha256 = blob.sha256 ?: continue
                    try {
                        // Count only a blob every server took: a partial push
                        // still leaves it missing somewhere.
                        val result = blossomService.pushLocalToMirrors(sha256)
                        if (result is BlossomService.MirrorPushResult.AllAccepted) {
                            pushed++
                        } else {
                            addLog("${sha256.take(8)}: ${result.message}", BlossomActivityLog.LogLevel.WARNING)
                        }
                    } catch (e: Exception) {
                        addLog("Failed to push ${sha256.take(8)}: ${e.message}", BlossomActivityLog.LogLevel.WARNING)
                    }
                    _syncProgress.value = (index + 1).toFloat() / needsPush.size
                    _syncMessage.value = "Pushed ${index + 1}/${needsPush.size}..."
                }

                val failed = needsPush.size - pushed
                _backedUpCount.value = blobs.size - failed
                if (failed == 0) {
                    addLog("Push complete: $pushed file(s) synced", BlossomActivityLog.LogLevel.SUCCESS)
                    _syncMessage.value = "Push complete: $pushed file(s)"
                } else {
                    addLog("Push finished with $failed failure(s) ($pushed succeeded)", BlossomActivityLog.LogLevel.WARNING)
                    _syncMessage.value = "$pushed succeeded, $failed failed"
                }
                loadDashboard()
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
