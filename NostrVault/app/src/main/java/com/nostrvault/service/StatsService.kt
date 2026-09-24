package com.nostrvault.service

import android.util.Log
import com.nostrvault.data.local.ConfigStore
import com.nostrvault.data.remote.WebSocketClient
import kotlinx.coroutines.*
import kotlinx.coroutines.flow.*
import kotlinx.serialization.json.*
import java.io.File
import java.io.FileInputStream
import java.security.cert.X509Certificate
import java.util.UUID
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.atomic.AtomicBoolean
import javax.inject.Inject
import javax.inject.Singleton
import javax.net.ssl.SSLContext
import javax.net.ssl.TrustManager
import javax.net.ssl.X509TrustManager

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
     * Fetch event counts by kind from relay endpoints.
     */
    suspend fun fetchCountsByKind() {
        _isUpdatingCount.value = true

        withContext(Dispatchers.IO) {
            val config = configStore.config.value
            val relayUrls = buildList {
                config.nostrURL?.let { add(it) }
                config.localInboxURL?.let { add(it) }
            }.distinct()

            if (relayUrls.isEmpty()) {
                withContext(Dispatchers.Main.immediate) {
                    _isUpdatingCount.value = false
                }
                return@withContext
            }

            val kinds = listOf(
                0, 1, 3, 4, 5, 6, 7, 9, 11, 12, 16,
                1059, 1063, 9735,
                10000, 10002, 10050, 10063,
                30023, 30078,
                39000, 39001, 39002,
            )

            val allCounts = ConcurrentHashMap<Int, Int>()
            var totalEvents = 0

            for (relayUrl in relayUrls) {
                val counts = fetchKindCounts(relayUrl, kinds)
                for ((kind, count) in counts) {
                    allCounts[kind] = (allCounts[kind] ?: 0) + count
                    totalEvents += count
                }
            }

            withContext(Dispatchers.Main.immediate) {
                _kindCounts.value = allCounts.toMap()
                _loadedEventsCount.value = totalEvents
                _isUpdatingCount.value = false
            }
        }
    }

    private suspend fun fetchKindCounts(relayUrl: String, kinds: List<Int>): Map<Int, Int> {
        val results = ConcurrentHashMap<Int, Int>()

        return suspendCancellableCoroutine { cont ->
            val client = WebSocketClient(url = relayUrl, scope = scope, trustLocalhost = isLocalhost(relayUrl))
            val pendingKinds = kinds.toMutableSet()
            val completed = AtomicBoolean(false)

            scope.launch {
                client.messages.collect { msg ->
                    try {
                        val parsed = json.parseToJsonElement(msg).jsonArray
                        val type = parsed[0].jsonPrimitive.contentOrNull

                        when (type) {
                            "COUNT" -> {
                                if (parsed.size >= 3) {
                                    val subId = parsed[1].jsonPrimitive.contentOrNull ?: ""
                                    val countObj = parsed[2].jsonObject
                                    val count = countObj["count"]?.jsonPrimitive?.intOrNull ?: 0

                                    // Extract kind from subscription ID
                                    val kindStr = subId.removePrefix("count-")
                                    val kind = kindStr.toIntOrNull()
                                    if (kind != null) {
                                        results[kind] = count
                                        pendingKinds.remove(kind)
                                    }

                                    if (pendingKinds.isEmpty() && completed.compareAndSet(false, true)) {
                                        client.disconnect()
                                        cont.resume(results.toMap()) { _, _, _ -> }
                                    }
                                }
                            }
                        }
                    } catch (_: Exception) {}
                }
            }

            client.connect()

            // Send COUNT requests for each kind
            for (kind in kinds) {
                val subId = "count-$kind"
                val filter = """{"kinds":[$kind]}"""
                client.send("[\"COUNT\",\"$subId\",$filter]")
            }

            // Timeout
            scope.launch {
                delay(10_000)
                if (completed.compareAndSet(false, true)) {
                    client.disconnect()
                    cont.resume(results.toMap()) { _, _, _ -> }
                }
            }

            cont.invokeOnCancellation {
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

    /** Trust self-signed certs for localhost connections. */
    private fun okhttp3.OkHttpClient.Builder.applyLocalhostTrust(): okhttp3.OkHttpClient.Builder {
        val trustManager = object : X509TrustManager {
            override fun checkClientTrusted(chain: Array<X509Certificate>, authType: String) {}
            override fun checkServerTrusted(chain: Array<X509Certificate>, authType: String) {}
            override fun getAcceptedIssuers(): Array<X509Certificate> = arrayOf()
        }
        val sslContext = SSLContext.getInstance("TLS")
        sslContext.init(null, arrayOf<TrustManager>(trustManager), null)
        sslSocketFactory(sslContext.socketFactory, trustManager)
        hostnameVerifier { hostname, _ ->
            hostname == "127.0.0.1" || hostname == "localhost" ||
                hostname.startsWith("192.168.") || hostname.startsWith("10.")
        }
        return this
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
