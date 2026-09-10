package com.nostrvault.service

import android.util.Base64
import android.util.Log
import com.nostrvault.data.local.ConfigStore
import com.nostrvault.data.remote.BlossomClient
import kotlinx.coroutines.*
import kotlinx.serialization.json.*
import okhttp3.*
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.RequestBody.Companion.asRequestBody
import okhttp3.RequestBody.Companion.toRequestBody
import java.io.File
import java.io.IOException
import java.security.MessageDigest
import java.security.cert.X509Certificate
import java.util.concurrent.TimeUnit
import javax.inject.Inject
import javax.inject.Singleton
import javax.net.ssl.SSLContext
import javax.net.ssl.TrustManager
import javax.net.ssl.X509TrustManager

/**
 * Full Blossom media service.
 * Handles BUD-02 uploads, mirroring to external servers,
 * downloading, deletion, and mirror status checks.
 *
 * Port of BlossomService.swift.
 */
@Singleton
class BlossomService @Inject constructor(
    private val configStore: ConfigStore,
    private val nostrService: NostrService,
    private val mediaCacheService: MediaCacheService,
) {
    companion object {
        private const val TAG = "BlossomService"
        private const val AUTH_KIND = 24242
        private const val MAX_UPLOAD_RETRIES = 3

        /** Hard ceiling on any single downloaded blob held in memory. */
        private const val MAX_BLOB_BYTES = 50L * 1024 * 1024 // 50 MB
    }

    private val json = Json { ignoreUnknownKeys = true }
    private val localClient = OkHttpClient.Builder()
        .connectTimeout(30, TimeUnit.SECONDS)
        .writeTimeout(120, TimeUnit.SECONDS)
        .readTimeout(60, TimeUnit.SECONDS)
        .applyLocalhostTrust()
        .build()

    private val remoteClient = OkHttpClient.Builder()
        .connectTimeout(30, TimeUnit.SECONDS)
        .writeTimeout(600, TimeUnit.SECONDS) // 10min for large files
        .readTimeout(900, TimeUnit.SECONDS) // 15min resource timeout
        .build()

    // ══════════════════════════════════════════════════════════════════
    // Upload + Mirror
    // ══════════════════════════════════════════════════════════════════

    /**
     * Upload to local relay, then mirror to external servers.
     * @return External URL from first successful mirror, or null.
     */
    suspend fun uploadAndMirror(
        data: ByteArray,
        sha256: String,
        contentType: String,
        onProgress: ((Float) -> Unit)? = null,
    ): String? = withContext(Dispatchers.IO) {
        // 1. Save to local relay
        saveToLocalRelay(data, sha256, contentType)

        // 2. Mirror to external servers
        val mirrors = configStore.config.value.activeBlossomMirrors
        if (mirrors.isEmpty()) return@withContext null

        var firstExternalUrl: String? = null
        val jobs = mirrors.map { mirrorUrl ->
            async {
                try {
                    val url = uploadToServer(
                        source = UploadSource.Data(data),
                        serverUrl = mirrorUrl,
                        sha256 = sha256,
                        contentType = contentType,
                    )
                    if (firstExternalUrl == null) firstExternalUrl = url
                    url
                } catch (e: Exception) {
                    Log.w(TAG, "Mirror to $mirrorUrl failed: ${e.message}")
                    null
                }
            }
        }
        jobs.awaitAll()
        firstExternalUrl
    }

    suspend fun uploadAndMirror(
        fileURL: File,
        sha256: String,
        contentType: String,
        onProgress: ((Float) -> Unit)? = null,
    ): String? = withContext(Dispatchers.IO) {
        saveToLocalRelay(fileURL, sha256, contentType)

        val mirrors = configStore.config.value.activeBlossomMirrors
        if (mirrors.isEmpty()) return@withContext null

        var firstExternalUrl: String? = null
        val jobs = mirrors.map { mirrorUrl ->
            async {
                try {
                    val url = uploadToServer(
                        source = UploadSource.FileSource(fileURL),
                        serverUrl = mirrorUrl,
                        sha256 = sha256,
                        contentType = contentType,
                    )
                    if (firstExternalUrl == null) firstExternalUrl = url
                    url
                } catch (e: Exception) {
                    Log.w(TAG, "Mirror to $mirrorUrl failed: ${e.message}")
                    null
                }
            }
        }
        jobs.awaitAll()
        firstExternalUrl
    }

    // ══════════════════════════════════════════════════════════════════
    // Local relay upload
    // ══════════════════════════════════════════════════════════════════

    fun saveToLocalRelay(data: ByteArray, sha256: String, contentType: String): Boolean {
        val url = localBlossomURL() ?: return false
        return try {
            val authHeader = createAuthHeader("upload", sha256, "$url/upload")
            val request = Request.Builder()
                .url("$url/upload")
                .put(data.toRequestBody(contentType.toMediaType()))
                .addHeader("Authorization", "Nostr $authHeader")
                .addHeader("Content-Type", contentType)
                .build()

            val response = localClient.newCall(request).execute()
            response.isSuccessful
        } catch (e: Exception) {
            Log.w(TAG, "Local upload failed: ${e.message}")
            false
        }
    }

    fun saveToLocalRelay(fileURL: File, sha256: String, contentType: String): Boolean {
        val url = localBlossomURL() ?: return false
        return try {
            val authHeader = createAuthHeader("upload", sha256, "$url/upload")
            val request = Request.Builder()
                .url("$url/upload")
                .put(fileURL.asRequestBody(contentType.toMediaType()))
                .addHeader("Authorization", "Nostr $authHeader")
                .addHeader("Content-Type", contentType)
                .build()

            val response = localClient.newCall(request).execute()
            response.isSuccessful
        } catch (e: Exception) {
            Log.w(TAG, "Local file upload failed: ${e.message}")
            false
        }
    }

    // ══════════════════════════════════════════════════════════════════
    // Remote server upload
    // ══════════════════════════════════════════════════════════════════

    /**
     * Upload to a specific server with retry logic.
     */
    suspend fun uploadToServer(
        source: UploadSource,
        serverUrl: String,
        sha256: String,
        contentType: String,
        onProgress: ((Float) -> Unit)? = null,
    ): String? = withContext(Dispatchers.IO) {
        val useLocal = isLocalhost(serverUrl)
        val client = if (useLocal) localClient else remoteClient

        var lastError: Exception? = null
        repeat(MAX_UPLOAD_RETRIES) { attempt ->
            try {
                val authHeader = createAuthHeader("upload", sha256, "$serverUrl/upload")

                val body = when (source) {
                    is UploadSource.Data -> source.data.toRequestBody(contentType.toMediaType())
                    is UploadSource.FileSource -> source.file.asRequestBody(contentType.toMediaType())
                }

                val request = Request.Builder()
                    .url("$serverUrl/upload")
                    .put(body)
                    .addHeader("Authorization", "Nostr $authHeader")
                    .addHeader("Content-Type", contentType)
                    .build()

                val response = client.newCall(request).execute()
                if (response.isSuccessful) {
                    return@withContext "$serverUrl/$sha256"
                }

                lastError = IOException("Upload failed: ${response.code} ${response.message}")

                if (attempt < MAX_UPLOAD_RETRIES - 1) {
                    delay(1000L * (attempt + 1)) // Linear backoff
                }
            } catch (e: Exception) {
                lastError = e
                if (attempt < MAX_UPLOAD_RETRIES - 1) {
                    delay(1000L * (attempt + 1))
                }
            }
        }

        Log.w(TAG, "Upload to $serverUrl failed after $MAX_UPLOAD_RETRIES attempts: ${lastError?.message}")
        null
    }

    // ══════════════════════════════════════════════════════════════════
    // Download & mirroring
    // ══════════════════════════════════════════════════════════════════

    /**
     * Download from URL and save to local relay.
     */
    suspend fun downloadFromURL(url: String, mirrorToExternal: Boolean = false): ByteArray? {
        return withContext(Dispatchers.IO) {
            try {
                val request = Request.Builder().url(url).get().build()
                val response = remoteClient.newCall(request).execute()
                if (!response.isSuccessful) return@withContext null

                val data = readBodyCapped(response, MAX_BLOB_BYTES) ?: return@withContext null
                val sha256 = computeSHA256(data)

                // Save to local relay
                val contentType = response.header("Content-Type") ?: "application/octet-stream"
                saveToLocalRelay(data, sha256, contentType)

                if (mirrorToExternal) {
                    pushLocalToMirrors(sha256)
                }

                data
            } catch (e: Exception) {
                Log.w(TAG, "Download from $url failed: ${e.message}")
                null
            }
        }
    }

    suspend fun downloadFromMirrors(sha256: String): ByteArray? {
        val mirrors = configStore.config.value.activeBlossomMirrors
        for (mirror in mirrors) {
            try {
                val request = Request.Builder()
                    .url("$mirror/$sha256")
                    .get()
                    .build()

                val response = remoteClient.newCall(request).execute()
                if (response.isSuccessful) {
                    val data = readBodyCapped(response, MAX_BLOB_BYTES) ?: continue
                    // Blossom is content-addressed: the bytes MUST hash to the
                    // requested digest. A mismatch means a malicious/broken mirror;
                    // discard rather than poison the local cache.
                    if (computeSHA256(data) != sha256.lowercase()) {
                        Log.w(TAG, "Hash mismatch from mirror $mirror for $sha256, discarding")
                        continue
                    }
                    return data
                }
            } catch (e: Exception) {
                Log.w(TAG, "Download from mirror $mirror failed: ${e.message}")
            }
        }
        return null
    }

    /**
     * Push a local blob to all external mirrors.
     */
    suspend fun pushLocalToMirrors(sha256: String) = withContext(Dispatchers.IO) {
        val localUrl = localBlossomURL() ?: return@withContext

        // Download from local
        val data = try {
            val request = Request.Builder().url("$localUrl/$sha256").get().build()
            val response = localClient.newCall(request).execute()
            if (!response.isSuccessful) return@withContext
            readBodyCapped(response, MAX_BLOB_BYTES) ?: return@withContext
        } catch (e: Exception) {
            Log.w(TAG, "Local download failed: ${e.message}")
            return@withContext
        }

        val mirrors = configStore.config.value.activeBlossomMirrors
        val jobs = mirrors.map { mirror ->
            async {
                try {
                    uploadToServer(
                        source = UploadSource.Data(data),
                        serverUrl = mirror,
                        sha256 = sha256,
                        contentType = "application/octet-stream",
                    )
                } catch (e: Exception) {
                    Log.w(TAG, "Push to mirror $mirror failed: ${e.message}")
                    null
                }
            }
        }
        jobs.awaitAll()
    }

    /**
     * Mirror all blobs from external to local.
     */
    suspend fun mirrorAllFromExternal(
        onProgress: ((Float) -> Unit)? = null,
        onLogMessage: ((String) -> Unit)? = null,
    ) = withContext(Dispatchers.IO) {
        // Use only explicitly configured external mirrors, not activeBlossomMirrors.
        // activeBlossomMirrors prepends the Haven relay (which is our own server);
        // pulling from our own relay to itself doesn't make sense and causes timeouts.
        val mirrors = configStore.config.value.blossomMirrors
        val ownerPubkey = nostrService.ownerHexPubkey

        val allHashes = mutableSetOf<String>()

        for (mirror in mirrors) {
            val blobs = fetchBlobList(mirror, ownerPubkey)
            blobs.mapNotNull { it.sha256 }.forEach { allHashes.add(it) }
            onLogMessage?.invoke("Listed ${blobs.size} blobs from $mirror")
        }

        // Filter to hashes not in local Blossom
        val missing = allHashes.filter { !mediaCacheService.isInLocalBlossom(it) }
        onLogMessage?.invoke("Found ${missing.size} blobs to mirror (${allHashes.size} total on mirrors)")

        val total = missing.size
        for ((index, hash) in missing.withIndex()) {
            val data = downloadFromMirrors(hash)
            if (data != null) {
                saveToLocalRelay(data, hash, "application/octet-stream")
            }
            val done = index + 1
            onProgress?.invoke(done.toFloat() / total)
            if (done % 10 == 0) onLogMessage?.invoke("Mirrored $done / $total")
            delay(150) // pace requests so the relay isn't overwhelmed
        }
    }

    // ══════════════════════════════════════════════════════════════════
    // Deletion
    // ══════════════════════════════════════════════════════════════════

    /**
     * Delete a blob from all external mirrors.
     */
    suspend fun deleteFromMirrors(sha256: String): Int = withContext(Dispatchers.IO) {
        val mirrors = configStore.config.value.activeBlossomMirrors
        var successCount = 0

        val jobs = mirrors.map { mirror ->
            async {
                try {
                    val authHeader = createAuthHeader("delete", sha256)
                    val request = Request.Builder()
                        .url("$mirror/$sha256")
                        .delete()
                        .addHeader("Authorization", "Nostr $authHeader")
                        .build()

                    val response = remoteClient.newCall(request).execute()
                    if (response.isSuccessful) {
                        synchronized(this@BlossomService) { successCount++ }
                    }
                } catch (e: Exception) {
                    Log.w(TAG, "Delete from $mirror failed: ${e.message}")
                }
            }
        }
        jobs.awaitAll()
        successCount
    }

    fun deleteFromLocal(sha256: String): Boolean {
        val config = configStore.config.value
        val dir = config.relayDataDir?.let { File(it, config.blossomPath) } ?: return false
        val exact = File(dir, sha256)
        if (exact.exists()) return exact.delete()

        // Try with extensions
        val extensions = listOf("jpg", "jpeg", "png", "gif", "webp", "mp4", "mov", "webm")
        for (ext in extensions) {
            val file = File(dir, "$sha256.$ext")
            if (file.exists()) return file.delete()
        }
        return false
    }

    // ══════════════════════════════════════════════════════════════════
    // Mirror status
    // ══════════════════════════════════════════════════════════════════

    /**
     * Check if a blob exists on each mirror.
     */
    suspend fun checkMirrorStatus(sha256: String): Map<String, Boolean> = withContext(Dispatchers.IO) {
        val mirrors = configStore.config.value.activeBlossomMirrors
        val results = mutableMapOf<String, Boolean>()

        val jobs = mirrors.map { mirror ->
            async {
                val exists = checkBlobExists(mirror, sha256)
                synchronized(results) { results[mirror] = exists }
            }
        }
        jobs.awaitAll()
        results
    }

    private fun checkBlobExists(mirror: String, sha256: String): Boolean {
        return try {
            val request = Request.Builder()
                .url("$mirror/$sha256")
                .head()
                .build()

            val response = remoteClient.newCall(request).execute()
            response.isSuccessful
        } catch (e: Exception) {
            false
        }
    }

    // ══════════════════════════════════════════════════════════════════
    // Blob list
    // ══════════════════════════════════════════════════════════════════

    suspend fun fetchBlobList(serverUrl: String, pubkey: String): List<BlobDescriptor> =
        withContext(Dispatchers.IO) {
            try {
                val authHeader = createListAuthHeader()
                val clientBuilder = OkHttpClient.Builder()
                    .connectTimeout(15, TimeUnit.SECONDS)
                    .readTimeout(15, TimeUnit.SECONDS)
                if (isLocalhost(serverUrl)) clientBuilder.applyLocalhostTrust()
                val client = clientBuilder.build()

                val reqBuilder = Request.Builder()
                    .url("$serverUrl/list/$pubkey")
                    .get()
                if (authHeader.isNotEmpty()) reqBuilder.addHeader("Authorization", "Nostr $authHeader")
                val response = client.newCall(reqBuilder.build()).execute()

                if (!response.isSuccessful) {
                    Log.w(TAG, "fetchBlobList $serverUrl returned HTTP ${response.code}")
                    return@withContext emptyList()
                }
                val body = response.body?.string() ?: return@withContext emptyList()
                json.decodeFromString<List<BlobDescriptor>>(body)
            } catch (e: Exception) {
                Log.w(TAG, "fetchBlobList $serverUrl failed: ${e.message}")
                emptyList()
            }
        }

    private fun createListAuthHeader(): String {
        val expiration = (System.currentTimeMillis() / 1000) + 3600
        val tags = listOf(
            listOf("t", "list"),
            listOf("expiration", expiration.toString()),
        )
        val event = nostrService.signEvent(
            kind = AUTH_KIND,
            content = "List blobs",
            tags = tags,
            forceOwner = true,
        ) ?: return ""

        return buildEventBase64(event)
    }

    private fun buildEventBase64(event: NostrEvent): String {
        val eventJson = buildString {
            val tagsJson = event.tags.joinToString(",") { tag ->
                "[${tag.joinToString(",") { "\"$it\"" }}]"
            }
            append("{\"id\":\"${event.id}\",")
            append("\"pubkey\":\"${event.pubkey}\",")
            append("\"created_at\":${event.createdAt},")
            append("\"kind\":${event.kind},")
            append("\"tags\":[$tagsJson],")
            append("\"content\":\"${event.content}\",")
            append("\"sig\":\"${event.sig}\"}")
        }
        return Base64.encodeToString(eventJson.toByteArray(), Base64.NO_WRAP)
    }

    // ══════════════════════════════════════════════════════════════════
    // Auth header generation
    // ══════════════════════════════════════════════════════════════════

    /**
     * Create a Blossom auth header (kind 24242 signed event as base64).
     */
    private fun createAuthHeader(
        operation: String,
        sha256: String,
        uploadUrl: String? = null,
    ): String {
        val expiration = (System.currentTimeMillis() / 1000) + 300 // 5 minutes
        val tags = mutableListOf(
            listOf("t", operation),
            listOf("x", sha256),
            listOf("expiration", expiration.toString()),
        )
        uploadUrl?.let { tags.add(listOf("u", it)) }

        val event = nostrService.signEvent(
            kind = AUTH_KIND,
            content = "",
            tags = tags,
            forceOwner = true,
        ) ?: return ""

        return buildEventBase64(event)
    }

    // ══════════════════════════════════════════════════════════════════
    // Utilities
    // ══════════════════════════════════════════════════════════════════

    fun localBlossomURL(): String? {
        val config = configStore.config.value
        val port = config.relayPort ?: return null
        // Android relay runs without TLS (HAVEN_ENABLE_TLS=0), use plain http.
        // iOS/macOS use https because App Transport Security requires it there.
        return "http://127.0.0.1:$port"
    }

    private fun isLocalhost(url: String): Boolean {
        val lower = url.lowercase()
        return lower.contains("localhost") || lower.contains("127.0.0.1") || lower.contains("0.0.0.0")
    }

    private fun computeSHA256(data: ByteArray): String {
        val digest = MessageDigest.getInstance("SHA-256")
        return digest.digest(data).joinToString("") { "%02x".format(it) }
    }

    /** Streaming SHA-256 of a file (does not load the whole file into memory). */
    fun computeSHA256(file: File): String {
        val digest = MessageDigest.getInstance("SHA-256")
        file.inputStream().use { input ->
            val buffer = ByteArray(64 * 1024)
            var read: Int
            while (input.read(buffer).also { read = it } != -1) {
                digest.update(buffer, 0, read)
            }
        }
        return digest.digest().joinToString("") { "%02x".format(it) }
    }

    /**
     * Read a response body into memory with a hard byte ceiling.
     * Rejects up-front on an oversized Content-Length and aborts mid-stream if a
     * missing/lying length lets the body exceed [maxBytes]. Prevents a hostile or
     * broken server from OOM-killing the app with a giant blob.
     */
    private fun readBodyCapped(response: Response, maxBytes: Long): ByteArray? {
        val body = response.body ?: return null
        return body.use {
            val declared = it.contentLength()
            if (declared > maxBytes) {
                Log.w(TAG, "Rejecting oversized body: Content-Length=$declared > $maxBytes")
                return null
            }
            val source = it.source()
            val sink = okio.Buffer()
            var total = 0L
            while (true) {
                val n = source.read(sink, 64 * 1024L)
                if (n == -1L) break
                total += n
                if (total > maxBytes) {
                    Log.w(TAG, "Aborting oversized body mid-stream at $total bytes")
                    return null
                }
            }
            sink.readByteArray()
        }
    }

    /** Trust self-signed certs for localhost connections. */
    private fun OkHttpClient.Builder.applyLocalhostTrust(): OkHttpClient.Builder {
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

    sealed class UploadSource {
        data class Data(val data: ByteArray) : UploadSource() {
            val byteCount: Int get() = data.size
        }
        data class FileSource(val file: File) : UploadSource() {
            val byteCount: Long get() = file.length()
        }
    }
}
