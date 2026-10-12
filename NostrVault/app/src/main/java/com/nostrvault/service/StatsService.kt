package com.nostrvault.service

import android.util.Log
import com.nostrvault.data.local.ConfigStore
import com.nostrvault.data.remote.LocalTls
import com.nostrvault.data.remote.WebSocketClient
import kotlinx.coroutines.*
import kotlinx.coroutines.flow.*
import kotlinx.serialization.json.*
import java.io.File
import java.io.FileInputStream
import java.util.UUID
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.atomic.AtomicBoolean
import javax.inject.Inject
import javax.inject.Singleton

/**
 * Storage statistics and event count tracking service.
 *
 * Port of StatsService.swift.
 */
@Singleton
class StatsService @Inject constructor(
    private val configStore: ConfigStore,
) {
    companion object {
        private const val TAG = "StatsService"
        // Magic bytes for file type detection
        private val JPEG_MAGIC = byteArrayOf(0xFF.toByte(), 0xD8.toByte(), 0xFF.toByte())
        private val PNG_MAGIC = byteArrayOf(0x89.toByte(), 0x50, 0x4E, 0x47)
        private val GIF_MAGIC = "GIF8".toByteArray()
        private val WEBP_MAGIC = "RIFF".toByteArray()

        /** The relay's real total in a counts map, alongside the kinds (iOS key -1). */
        const val TOTAL_KEY = -1

        /**
         * The kinds counted one by one: the "In your vault" groups and the
         * kinds "Other" names (iOS `VaultContents.countedKinds`).
         */
        val COUNTED_KINDS = listOf(
            0, 1, 3, 4, 5, 6, 7, 8, 9, 16, 20, 21, 22,
            1059, 1063, 1068, 1111, 1311, 1808,
            9734, 9735, 9802,
            10000, 10001, 10002, 10003, 10005, 10006, 10015, 10030, 10050, 10063,
            30000, 30001, 30002, 30003, 30008, 30009, 30023, 30024, 30030, 30078,
        )

        /**
         * Every endpoint the vault stores events on. An external relay folds
         * them onto one URL, so it is asked (and counted) once.
         */
        internal fun countEndpoints(config: com.nostrvault.relay.HavenConfig): List<String> =
            listOfNotNull(
                config.nostrURL,
                config.localRelayURL("inbox"),
                config.localRelayURL("private"),
                config.localRelayURL("chat"),
            ).distinct()

        /** Each endpoint's counts summed per key; null when there were none, or one did not answer. */
        internal fun mergeEndpointCounts(perEndpoint: List<Map<Int, Int>?>): Map<Int, Int>? {
            if (perEndpoint.isEmpty() || perEndpoint.any { it == null }) return null
            val merged = HashMap<Int, Int>()
            for (counts in perEndpoint) for ((kind, count) in counts!!) merged[kind] = (merged[kind] ?: 0) + count
            return merged
        }
    }

    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)
    private val json = Json { ignoreUnknownKeys = true }

    // ── Observable state ──────────────────────────────────────────────

    private val _storageSize = MutableStateFlow(0L)
    val storageSize: StateFlow<Long> = _storageSize.asStateFlow()

    private val _blossomSize = MutableStateFlow(0L)
    val blossomSize: StateFlow<Long> = _blossomSize.asStateFlow()

    private val _cacheSize = MutableStateFlow(0L)
    val cacheSize: StateFlow<Long> = _cacheSize.asStateFlow()

    private val _thumbnailSize = MutableStateFlow(0L)
    val thumbnailSize: StateFlow<Long> = _thumbnailSize.asStateFlow()

    private val _loadedEventsCount = MutableStateFlow(0)
    val loadedEventsCount: StateFlow<Int> = _loadedEventsCount.asStateFlow()

    private val _isUpdatingCount = MutableStateFlow(false)
    val isUpdatingCount: StateFlow<Boolean> = _isUpdatingCount.asStateFlow()

    // Per-kind counts
    private val _kindCounts = MutableStateFlow<Map<Int, Int>>(emptyMap())
    val kindCounts: StateFlow<Map<Int, Int>> = _kindCounts.asStateFlow()

    /** The kinds `fetchCountsByKind` was asked to count for one account (`authors`), summed per kind. */
    private val _yourKindCounts = MutableStateFlow<Map<Int, Int>>(emptyMap())
    val yourKindCounts: StateFlow<Map<Int, Int>> = _yourKindCounts.asStateFlow()

    // Baseline tracking
    var baseDbCount = 0
        private set
    var baseRelayNotesStored = 0
        private set

    // ══════════════════════════════════════════════════════════════════
    // Storage stats
    // ══════════════════════════════════════════════════════════════════

    fun refreshStats() {
        scope.launch(Dispatchers.IO) {
            val config = configStore.config.value
            val relayDir = config.relayDataDir

            if (relayDir != null) {
                val dbSize = calculateSize(File(relayDir))
                withContext(Dispatchers.Main.immediate) { _storageSize.value = dbSize }
            }

            val blossomDir = config.relayDataDir?.let { "$it/${config.blossomPath}" }
            if (blossomDir != null) {
                val bSize = calculateSize(File(blossomDir))
                withContext(Dispatchers.Main.immediate) { _blossomSize.value = bSize }
            }

            val cacheDir = config.appSupportDir?.let { "$it/media_cache" }
            if (cacheDir != null) {
                val cSize = calculateSize(File(cacheDir))
                withContext(Dispatchers.Main.immediate) { _cacheSize.value = cSize }
            }

            val thumbDir = config.appSupportDir?.let { "$it/thumbnails" }
            if (thumbDir != null) {
                val tSize = calculateSize(File(thumbDir))
                withContext(Dispatchers.Main.immediate) { _thumbnailSize.value = tSize }
            }
        }
    }

    /**
     * Fetch event counts by kind from every endpoint the vault stores events
     * on (outbox, `/inbox`, `/private`, `/chat`), plus one `{}` COUNT per
     * endpoint for the real total. Port of iOS `fetchCountsByKind`: when any
     * endpoint does not answer, nothing is published, so the numbers never
     * drop to a partial sum. With [author] (hex), [yourKinds] are also
     * counted for that account alone, into [yourKindCounts]; without one,
     * [yourKindCounts] keeps what it had.
     *
     * @return whether every endpoint answered and the counts were published.
     */
    suspend fun fetchCountsByKind(author: String? = null, yourKinds: Collection<Int> = emptyList()): Boolean {
        _isUpdatingCount.value = true

        return withContext(Dispatchers.IO) {
            val relayUrls = countEndpoints(configStore.config.value)
            val perEndpoint = coroutineScope {
                relayUrls.map { url ->
                    async { fetchKindCounts(url, COUNTED_KINDS, author?.let { it to yourKinds.toList() }) }
                }.awaitAll()
            }
            val merged = mergeEndpointCounts(perEndpoint.map { it?.first })
            val yours = mergeEndpointCounts(perEndpoint.map { it?.second })
            if (merged == null) Log.w(TAG, "Not every endpoint answered the counts; keeping the last ones")

            withContext(Dispatchers.Main.immediate) {
                if (merged != null && yours != null) {
                    _kindCounts.value = merged.filterKeys { it != TOTAL_KEY }
                    if (author != null) _yourKindCounts.value = yours
                    _loadedEventsCount.value = merged[TOTAL_KEY] ?: 0
                }
                _isUpdatingCount.value = false
            }
            merged != null && yours != null
        }
    }

    /**
     * One COUNT per kind plus one `{}` total (under [TOTAL_KEY]) over a
     * single connection, and with [yours] (author hex, kinds) one more per
     * kind for that account (the second map). Null unless every request was
     * answered in time.
     */
    private suspend fun fetchKindCounts(
        relayUrl: String,
        kinds: List<Int>,
        yours: Pair<String, List<Int>>?,
    ): Pair<Map<Int, Int>, Map<Int, Int>>? {
        val author = yours?.first
        val results = ConcurrentHashMap<Int, Int>()
        val yourResults = ConcurrentHashMap<Int, Int>()
        val tag = UUID.randomUUID().toString().take(6)
        val subIdToKind = buildMap {
            put("count-total-$tag", TOTAL_KEY)
            for (kind in kinds) put("count-k$kind-$tag", kind)
        }
        val yourSubIdToKind = yours?.second.orEmpty().associateBy { "count-a$it-$tag" }

        return suspendCancellableCoroutine { cont ->
            val client = WebSocketClient(url = relayUrl, scope = scope, trustLocalhost = isLocalhost(relayUrl))
            val pending = ConcurrentHashMap.newKeySet<String>().apply {
                addAll(subIdToKind.keys)
                addAll(yourSubIdToKind.keys)
            }
            val completed = AtomicBoolean(false)
            var listener: Job? = null
            var timeout: Job? = null

            fun finish(answer: Pair<Map<Int, Int>, Map<Int, Int>>?) {
                if (!completed.compareAndSet(false, true)) return
                listener?.cancel()
                timeout?.cancel()
                client.disconnect()
                cont.resume(answer) { _, _, _ -> }
            }

            listener = scope.launch {
                client.messages.collect { msg ->
                    try {
                        val parsed = json.parseToJsonElement(msg).jsonArray
                        if (parsed.size < 3 || parsed[0].jsonPrimitive.contentOrNull != "COUNT") return@collect
                        val subId = parsed[1].jsonPrimitive.contentOrNull ?: return@collect
                        val into = if (subId in yourSubIdToKind) yourResults else results
                        val kind = subIdToKind[subId] ?: yourSubIdToKind[subId] ?: return@collect
                        val count = (parsed[2].jsonObject["count"] as? JsonPrimitive)?.let {
                            it.intOrNull ?: it.doubleOrNull?.toInt() ?: it.contentOrNull?.toIntOrNull()
                        } ?: 0
                        into[kind] = count
                        pending.remove(subId)
                        if (pending.isEmpty()) finish(results.toMap() to yourResults.toMap())
                    } catch (_: Exception) {}
                }
            }

            client.connect()

            for ((subId, kind) in subIdToKind) {
                val filter = if (kind == TOTAL_KEY) "{}" else """{"kinds":[$kind]}"""
                client.send("[\"COUNT\",\"$subId\",$filter]")
            }
            for ((subId, kind) in yourSubIdToKind) {
                client.send("[\"COUNT\",\"$subId\",{\"kinds\":[$kind],\"authors\":[\"$author\"]}]")
            }

            timeout = scope.launch {
                delay(20_000)
                finish(null)
            }

            cont.invokeOnCancellation {
                listener?.cancel()
                timeout?.cancel()
                client.disconnect()
            }
        }
    }

    // ══════════════════════════════════════════════════════════════════
    // Blossom blob listing
    // ══════════════════════════════════════════════════════════════════

    suspend fun fetchBlobList(pubkey: String): List<BlobDescriptor> =
        fetchBlobList(pubkey, configStore.config.value.localBlossomBaseURL)

    /**
     * List the blobs a server holds for [pubkey] via the Blossom `/list/<pubkey>`
     * endpoint. [baseUrl] may be the local relay (wss/ws) or an external mirror (https).
     */
    suspend fun fetchBlobList(pubkey: String, baseUrl: String?): List<BlobDescriptor> = withContext(Dispatchers.IO) {
        val resolvedBase = baseUrl ?: return@withContext emptyList()
        val httpUrl = wsToHttp(resolvedBase)

        try {
            val request = okhttp3.Request.Builder()
                .url("$httpUrl/list/$pubkey")
                .get()
                .build()

            val clientBuilder = okhttp3.OkHttpClient.Builder()
                .connectTimeout(10, java.util.concurrent.TimeUnit.SECONDS)
                .readTimeout(10, java.util.concurrent.TimeUnit.SECONDS)
            if (isLocalhost(resolvedBase)) clientBuilder.applyLocalhostTrust()
            val client = clientBuilder.build()

            val response = client.newCall(request).execute()
            if (!response.isSuccessful) return@withContext emptyList()

            val body = response.body?.string() ?: return@withContext emptyList()
            json.decodeFromString<List<BlobDescriptor>>(body)
        } catch (e: Exception) {
            Log.w(TAG, "Blob list fetch failed: ${e.message}")
            emptyList()
        }
    }

    // ══════════════════════════════════════════════════════════════════
    // File utilities
    // ══════════════════════════════════════════════════════════════════

    fun calculateSize(directory: File): Long {
        if (!directory.exists()) return 0L
        var total = 0L
        directory.walkTopDown().forEach { file ->
            if (file.isFile) {
                total += file.length()
            }
        }
        return total
    }

    fun calculateCacheBreakdown(relayDir: String): CacheBreakdown {
        val dir = File(relayDir)
        if (!dir.exists()) return CacheBreakdown()

        var imageCount = 0; var imageSize = 0L
        var videoCount = 0; var videoSize = 0L
        var otherCount = 0; var otherSize = 0L
        var oldestDate = Long.MAX_VALUE
        var newestDate = 0L

        dir.walkTopDown().forEach { file ->
            if (!file.isFile) return@forEach
            val size = file.length()
            val modified = file.lastModified()

            if (modified < oldestDate) oldestDate = modified
            if (modified > newestDate) newestDate = modified

            when (detectFileType(file)) {
                FileType.IMAGE -> { imageCount++; imageSize += size }
                FileType.VIDEO -> { videoCount++; videoSize += size }
                else -> { otherCount++; otherSize += size }
            }
        }

        return CacheBreakdown(
            imageCount = imageCount, imageSize = imageSize,
            videoCount = videoCount, videoSize = videoSize,
            otherCount = otherCount, otherSize = otherSize,
            oldestDate = if (oldestDate == Long.MAX_VALUE) null else oldestDate,
            newestDate = if (newestDate == 0L) null else newestDate,
        )
    }

    fun detectFileType(file: File): FileType {
        if (!file.exists() || file.length() < 4) return FileType.OTHER

        try {
            val header = ByteArray(12)
            FileInputStream(file).use { it.read(header) }

            return when {
                header.startsWith(JPEG_MAGIC) -> FileType.IMAGE
                header.startsWith(PNG_MAGIC) -> FileType.IMAGE
                header.startsWith(GIF_MAGIC) -> FileType.IMAGE
                header.startsWith(WEBP_MAGIC) && header.size >= 12 &&
                    header[8] == 'W'.code.toByte() && header[9] == 'E'.code.toByte() &&
                    header[10] == 'B'.code.toByte() && header[11] == 'P'.code.toByte() -> FileType.IMAGE
                // MP4/MOV: check for ftyp box
                header.size >= 8 && String(header, 4, 4) == "ftyp" -> FileType.VIDEO
                // WebM/MKV: check EBML header
                header[0] == 0x1A.toByte() && header[1] == 0x45.toByte() -> FileType.VIDEO
                else -> FileType.OTHER
            }
        } catch (e: Exception) {
            return FileType.OTHER
        }
    }

    // ── Combined fetch for DashboardScreen ─────────────────────────────

    suspend fun fetchStats(): StatsSnapshot {
        refreshStats()
        fetchCountsByKind()

        val counts = _kindCounts.value
        return StatsSnapshot(
            totalEvents = _loadedEventsCount.value,
            noteCount = (counts[1] ?: 0) + (counts[30023] ?: 0),
            dmCount = (counts[4] ?: 0) + (counts[1059] ?: 0),
            mediaFileCount = counts[1063] ?: 0,
            formattedTotalSize = formatSize(_storageSize.value + _blossomSize.value),
            formattedMediaSize = formatSize(_blossomSize.value),
        )
    }

    // ── Formatting ────────────────────────────────────────────────────

    fun formatSize(bytes: Long): String {
        return when {
            bytes < 1024 -> "$bytes B"
            bytes < 1024 * 1024 -> "%.1f KB".format(bytes / 1024.0)
            bytes < 1024 * 1024 * 1024 -> "%.1f MB".format(bytes / (1024.0 * 1024))
            else -> "%.2f GB".format(bytes / (1024.0 * 1024 * 1024))
        }
    }

    val formattedStorageSize: String get() = formatSize(_storageSize.value)
    val formattedBlossomSize: String get() = formatSize(_blossomSize.value)
    val formattedCacheSize: String get() = formatSize(_cacheSize.value)
    val formattedThumbnailSize: String get() = formatSize(_thumbnailSize.value)

    private fun ByteArray.startsWith(prefix: ByteArray): Boolean {
        if (size < prefix.size) return false
        for (i in prefix.indices) {
            if (this[i] != prefix[i]) return false
        }
        return true
    }

    private fun isLocalhost(url: String): Boolean {
        val lower = url.lowercase()
        return lower.contains("localhost") || lower.contains("127.0.0.1") || lower.contains("0.0.0.0")
    }

    /** Convert wss:// to https:// and ws:// to http:// for HTTP requests. */
    private fun wsToHttp(url: String): String = url
        .replace("wss://", "https://")
        .replace("ws://", "http://")

    /** This device's relay and LAN relays: trust follows [LocalTls]. */
    private fun okhttp3.OkHttpClient.Builder.applyLocalhostTrust(): okhttp3.OkHttpClient.Builder {
        return with(LocalTls) { localTrust() }
    }
}

// ── Supporting types ──────────────────────────────────────────────

enum class FileType { IMAGE, VIDEO, OTHER }

data class CacheBreakdown(
    val imageCount: Int = 0,
    val imageSize: Long = 0L,
    val videoCount: Int = 0,
    val videoSize: Long = 0L,
    val otherCount: Int = 0,
    val otherSize: Long = 0L,
    val oldestDate: Long? = null,
    val newestDate: Long? = null,
)

data class StatsSnapshot(
    val totalEvents: Int,
    val noteCount: Int,
    val dmCount: Int,
    val mediaFileCount: Int,
    val formattedTotalSize: String,
    val formattedMediaSize: String,
)

@kotlinx.serialization.Serializable
data class BlobDescriptor(
    val url: String? = null,
    val sha256: String? = null,
    val size: Long? = null,
    val type: String? = null,
    val uploaded: Long? = null,
)
