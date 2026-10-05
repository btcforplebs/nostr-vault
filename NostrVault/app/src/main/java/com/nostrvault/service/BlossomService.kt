package com.nostrvault.service

import android.util.Base64
import android.util.Log
import com.nostrvault.data.local.ConfigStore
import com.nostrvault.data.remote.BlossomClient
import kotlinx.coroutines.*
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.sync.withPermit
import kotlinx.serialization.json.*
import okhttp3.*
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.RequestBody.Companion.asRequestBody
import okhttp3.RequestBody.Companion.toRequestBody
import java.io.File
import java.io.IOException
import java.security.MessageDigest
import java.security.cert.X509Certificate
import java.util.concurrent.Semaphore
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

        /** Signer attempts for one Blossom auth event, and the pause between them. */
        private const val AUTH_SIGN_ATTEMPTS = 3
        private const val AUTH_SIGN_RETRY_DELAY_MS = 1_000L
        private const val MIRROR_CONCURRENCY = 4

        /** Hard ceiling on any single downloaded blob held in memory. */
        private const val MAX_BLOB_BYTES = 50L * 1024 * 1024 // 50 MB
    }

    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
    private val json = Json { ignoreUnknownKeys = true }
    private val mirrorSemaphore = Semaphore(MIRROR_CONCURRENCY)

    private val localClient = OkHttpClient.Builder()
        .connectTimeout(30, TimeUnit.SECONDS)
        .writeTimeout(120, TimeUnit.SECONDS)
        .readTimeout(60, TimeUnit.SECONDS)
        .applyLocalhostTrust()
        .build()

    /**
     * One mirror-from-servers run shared by Settings, the dashboard and the
     * Media tab's auto-mirror, like iOS MirrorService: a second start while
     * one runs is ignored.
     */
    data class MirrorRun(
        val running: Boolean = false,
        /** 0..1 once the blob count is known, else null. */
        val progress: Float? = null,
        val status: String = "",
        /** "Mirrored N files" / "All media already mirrored" after a run. */
        val lastResult: String = "",
    )

    private val _mirrorRun = MutableStateFlow(MirrorRun())
    val mirrorRun: StateFlow<MirrorRun> = _mirrorRun.asStateFlow()

    /** Starts a mirror-from-servers run; false if one is already running. */
    fun runMirror(): Boolean {
        synchronized(_mirrorRun) {
            if (_mirrorRun.value.running) return false
            _mirrorRun.value = MirrorRun(running = true, status = "Starting...")
        }
        scope.launch {
            val result = try {
                if (configStore.config.value.activeBlossomMirrors.isEmpty()) {
                    "No mirrors configured"
                } else {
                    val count = mirrorAllFromExternal(
                        onProgress = { pct -> _mirrorRun.value = _mirrorRun.value.copy(progress = pct) },
                        onLogMessage = { msg -> _mirrorRun.value = _mirrorRun.value.copy(status = msg) },
                    )
                    if (count > 0) "Mirrored $count files" else "All media already mirrored"
                }
            } catch (e: Exception) {
                Log.w(TAG, "Mirror run failed: ${e.message}")
                "Mirror failed: ${e.message}"
            }
            _mirrorRun.value = MirrorRun(lastResult = result)
        }
        return true
    }

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
     * @param allowLocalFallback when true, a successful local-relay save counts as
     *   success and the LOCAL url is returned if every external mirror fails —
     *   for save-to-vault flows (gallery/share-sheet) where the blob just needs
     *   to be stored. DMs must leave this false: a URL embedded in a published
     *   event must be reachable by other clients, and a localhost URL silently
     *   masks the mirror failure. The note composer uses [uploadForPost].
     */
    suspend fun uploadAndMirror(
        data: ByteArray,
        sha256: String,
        contentType: String,
        onProgress: ((Float) -> Unit)? = null,
        allowLocalFallback: Boolean = false,
    ): String? = uploadAndMirror(UploadSource.Data(data), sha256, contentType, allowLocalFallback)

    suspend fun uploadAndMirror(
        fileURL: File,
        sha256: String,
        contentType: String,
        onProgress: ((Float) -> Unit)? = null,
        allowLocalFallback: Boolean = false,
    ): String? = uploadAndMirror(UploadSource.FileSource(fileURL), sha256, contentType, allowLocalFallback)

    private suspend fun uploadAndMirror(
        source: UploadSource,
        sha256: String,
        contentType: String,
        allowLocalFallback: Boolean,
    ): String? {
        val attempt = upload(source, sha256, contentType, skipOutsideServers = false)
        return when (val outcome = attempt.outcome) {
            is PostUploadOutcome.Hosted -> outcome.url
            // Local-relay URL, only ever returned for save-to-vault flows.
            else -> if (allowLocalFallback) attempt.localUrl else null
        }
    }

    /**
     * Where a post's attachment ended up. Four situations with four different
     * remedies — they used to share one null and one message ("check your
     * connection"), which sent us looking at the network when the blob was
     * sitting safely in the phone's own relay.
     */
    sealed class PostUploadOutcome {
        /** An outside server accepted it; this URL goes in the note. */
        data class Hosted(val url: String) : PostUploadOutcome()

        /**
         * In this device's relay, but no outside server took it. The post can
         * wait for one (`MediaPostQueue`). [unreachable] is what was tried.
         */
        data class SavedOnDevice(val unreachable: List<String>) : PostUploadOutcome()

        /** In this device's relay, and there is no outside server to try. */
        data object NoOutsideServer : PostUploadOutcome()

        /** Never reached this device's relay (and no outside server took it either). */
        data object NotSavedOnDevice : PostUploadOutcome()
    }

    /**
     * Upload a note attachment: this device's relay first, then the outside
     * Blossom servers. [skipOutsideServers] saves locally only — used once an
     * earlier attachment of the same post found every outside server down, so
     * the rest don't each wait out the same 10 s retry.
     */
    suspend fun uploadForPost(
        fileURL: File,
        sha256: String,
        contentType: String,
        skipOutsideServers: Boolean = false,
        onProgress: ((Float) -> Unit)? = null,
    ): PostUploadOutcome =
        upload(UploadSource.FileSource(fileURL), sha256, contentType, skipOutsideServers).outcome

    /** What one upload did, plus the local URL when the local save succeeded. */
    private data class UploadAttempt(val outcome: PostUploadOutcome, val localUrl: String?)

    private suspend fun upload(
        source: UploadSource,
        sha256: String,
        contentType: String,
        skipOutsideServers: Boolean,
    ): UploadAttempt = withContext(Dispatchers.IO) {
        // Sign the BUD-02 auth event ONCE and reuse it for the local relay and
        // every mirror. The event is server-agnostic (no "u" tag), so one
        // signature is valid everywhere. This is required for external signers:
        // Amber serializes signing through a single activity and fails on the
        // concurrent requests that per-destination signing would produce.
        val authHeader = createAuthHeader("upload", sha256)
        if (authHeader.isEmpty()) {
            Log.e(TAG, "Upload aborted: could not create Blossom auth event (signer unavailable)")
            return@withContext UploadAttempt(PostUploadOutcome.NotSavedOnDevice, null)
        }

        val localUrl = localBlossomURL()
        val localOk = when {
            localUrl == null -> false
            source is UploadSource.Data -> saveToLocalRelay(source.data, sha256, contentType, authHeader)
            else -> saveToLocalRelay((source as UploadSource.FileSource).file, sha256, contentType, authHeader)
        }
        if (!localOk) Log.w(TAG, "Local relay upload failed for ${sha256.take(8)} — continuing with mirrors")
        val savedLocalUrl = if (localOk && localUrl != null) "$localUrl/$sha256" else null

        // What to report when no outside server hosted it: a post may only wait
        // for one if the blob is actually on this device.
        fun notHosted(mirrors: List<String>): PostUploadOutcome = when {
            !localOk -> PostUploadOutcome.NotSavedOnDevice
            mirrors.isEmpty() -> PostUploadOutcome.NoOutsideServer
            else -> PostUploadOutcome.SavedOnDevice(mirrors)
        }

        val mirrors = configStore.config.value.activeBlossomMirrors
        if (mirrors.isEmpty()) {
            Log.e(TAG, "No Blossom mirrors configured — refusing to embed a localhost media URL")
            return@withContext UploadAttempt(notHosted(mirrors), savedLocalUrl)
        }

        // Only skip when the blob is safe here; if the local save failed, an
        // outside server is the only place it can go, so try them anyway.
        if (skipOutsideServers && localOk) {
            Log.i(TAG, "Saved ${sha256.take(8)} on this device only — an earlier attachment found every outside server down")
            return@withContext UploadAttempt(PostUploadOutcome.SavedOnDevice(mirrors), savedLocalUrl)
        }

        var external = mirrorUploadPass(source, mirrors, sha256, contentType, authHeader)

        // A sleeping mirror host (e.g. the Mac relay over LAN/Tailscale) is often
        // woken *by* the first pass's connection attempts (wake-on-network) but
        // isn't up fast enough to serve it. Wait and retry the whole pass once
        // before handing the post to the queue.
        if (external == null) {
            Log.w(TAG, "All Blossom mirrors failed — retrying once in 10s in case a sleeping host is still waking")
            delay(10_000)
            external = mirrorUploadPass(source, mirrors, sha256, contentType, authHeader)
        }

        if (external == null) {
            Log.e(TAG, "All Blossom mirror uploads failed for ${sha256.take(8)} (saved on this device: $localOk)")
            return@withContext UploadAttempt(notHosted(mirrors), savedLocalUrl)
        }
        UploadAttempt(PostUploadOutcome.Hosted(external), savedLocalUrl)
    }

    /**
     * Send a blob that is already in this device's relay to the outside
     * servers, returning the URL of the first that accepts it. What
     * `MediaPostQueue` calls when it retries a waiting post. One pass only —
     * the queue itself is the retry.
     */
    suspend fun hostLocalBlob(sha256: String, contentType: String): String? = withContext(Dispatchers.IO) {
        val mirrors = configStore.config.value.activeBlossomMirrors
        if (mirrors.isEmpty()) {
            Log.w(TAG, "waiting post: no outside Blossom server configured — holding ${sha256.take(8)}")
            return@withContext null
        }
        val localBase = localBlossomURL() ?: return@withContext null

        // Stream through a temp file: a queued video can be far larger than
        // the in-memory blob cap.
        val temp = File.createTempFile("queued-${sha256.take(16)}-", ".blob")
        try {
            try {
                val request = Request.Builder().url("$localBase/$sha256").get().build()
                localClient.newCall(request).execute().use { response ->
                    if (!response.isSuccessful) {
                        Log.e(TAG, "waiting post: blob ${sha256.take(8)} not readable from this device's relay (HTTP ${response.code})")
                        return@withContext null
                    }
                    val body = response.body ?: return@withContext null
                    temp.outputStream().use { out -> body.byteStream().use { it.copyTo(out) } }
                }
            } catch (e: Exception) {
                Log.e(TAG, "waiting post: could not read blob ${sha256.take(8)} from this device's relay: ${e.message}")
                return@withContext null
            }

            val authHeader = createAuthHeader("upload", sha256)
            if (authHeader.isEmpty()) {
                Log.e(TAG, "waiting post: could not sign Blossom auth for ${sha256.take(8)} — will retry")
                return@withContext null
            }
            val hosted = mirrorUploadPass(UploadSource.FileSource(temp), mirrors, sha256, contentType, authHeader)
            if (hosted != null) {
                Log.i(TAG, "waiting post: ${sha256.take(8)} now hosted at $hosted")
            } else {
                Log.w(TAG, "waiting post: no outside server accepted ${sha256.take(8)} yet ($mirrors)")
            }
            hosted
        } finally {
            temp.delete()
        }
    }

    /** One concurrent upload pass over all mirrors; returns the first mirror URL that accepted the blob. */
    private suspend fun mirrorUploadPass(
        source: UploadSource,
        mirrors: List<String>,
        sha256: String,
        contentType: String,
        authHeader: String,
    ): String? = coroutineScope {
        val firstExternalUrl = java.util.concurrent.atomic.AtomicReference<String?>(null)
        val jobs = mirrors.map { mirrorUrl ->
            async {
                try {
                    val url = uploadToServer(
                        source = source,
                        serverUrl = mirrorUrl,
                        sha256 = sha256,
                        contentType = contentType,
                        authHeader = authHeader,
                    )
                    firstExternalUrl.compareAndSet(null, url)
                } catch (e: Exception) {
                    Log.w(TAG, "Mirror to $mirrorUrl failed: ${e.message}")
                }
            }
        }
        jobs.awaitAll()
        firstExternalUrl.get()
    }

    /**
     * Fire a cheap unauthenticated HEAD at every configured mirror so sleeping
     * hosts (notably a Mac relay woken by wake-on-network) start waking as soon
     * as the composer opens, instead of during the post itself. Fire-and-forget;
     * responses are ignored — this is connection warming only.
     */
    fun prewarmMirrors() {
        val mirrors = configStore.config.value.activeBlossomMirrors
        if (mirrors.isEmpty()) return
        scope.launch {
            mirrors.forEach { mirror ->
                launch {
                    try {
                        val client = if (isLocalhost(mirror)) localClient else remoteClient
                        val request = Request.Builder().url(mirror).head().build()
                        client.newCall(request).execute().close()
                    } catch (_: Exception) {
                        // Warming only — failures are expected while a host wakes.
                    }
                }
            }
        }
    }

    // ══════════════════════════════════════════════════════════════════
    // Local relay upload
    // ══════════════════════════════════════════════════════════════════

    suspend fun saveToLocalRelay(data: ByteArray, sha256: String, contentType: String, authHeader: String? = null): Boolean {
        val url = localBlossomURL() ?: return false
        return try {
            val auth = authHeader ?: createAuthHeader("upload", sha256)
            val request = Request.Builder()
                .url("$url/upload")
                .put(data.toRequestBody(contentType.toMediaType()))
                .addHeader("Authorization", "Nostr $auth")
                .addHeader("Content-Type", contentType)
                .build()

            val response = localClient.newCall(request).execute()
            response.isSuccessful
        } catch (e: Exception) {
            Log.w(TAG, "Local upload failed: ${e.message}")
            false
        }
    }

    suspend fun saveToLocalRelay(fileURL: File, sha256: String, contentType: String, authHeader: String? = null): Boolean {
        val url = localBlossomURL() ?: return false
        return try {
            val auth = authHeader ?: createAuthHeader("upload", sha256)
            val request = Request.Builder()
                .url("$url/upload")
                .put(fileURL.asRequestBody(contentType.toMediaType()))
                .addHeader("Authorization", "Nostr $auth")
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
        authHeader: String? = null,
        onProgress: ((Float) -> Unit)? = null,
    ): String? = withContext(Dispatchers.IO) {
        val useLocal = isLocalhost(serverUrl)
        val client = if (useLocal) localClient else remoteClient

        // Sign once (or reuse a caller-provided header). Signing per-retry would
        // hammer an external signer (Amber) and can fail under concurrency.
        val auth = authHeader ?: createAuthHeader("upload", sha256)

        var lastError: Exception? = null
        repeat(MAX_UPLOAD_RETRIES) { attempt ->
            try {
                val body = when (source) {
                    is UploadSource.Data -> source.data.toRequestBody(contentType.toMediaType())
                    is UploadSource.FileSource -> source.file.asRequestBody(contentType.toMediaType())
                }

                val request = Request.Builder()
                    .url("$serverUrl/upload")
                    .put(body)
                    .addHeader("Authorization", "Nostr $auth")
                    .addHeader("Content-Type", contentType)
                    .build()

                val response = client.newCall(request).execute()
                if (response.isSuccessful) {
                    return@withContext "$serverUrl/$sha256"
                }

                val errorBody = response.body?.string()?.take(500) ?: ""
                Log.w(TAG, "Mirror $serverUrl returned HTTP ${response.code}: $errorBody")
                lastError = IOException("HTTP ${response.code}: $errorBody")

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

    /**
     * Back up a piece of external feed media to the local relay's Blossom store.
     *
     * Port of iOS FeedMediaViewer.mirrorToBlossomTapped(): downloads the bytes,
     * derives their sha256, and uploads to the local relay. Unlike [downloadFromURL]
     * this reports whether the local save actually succeeded (it returns the blob's
     * sha256), so the feed viewer can show an accurate "Mirrored / Failed" result.
     *
     * @return the blob's sha256 on success, or null if the download or local save failed.
     */
    suspend fun mirrorUrlToLocal(url: String): String? = withContext(Dispatchers.IO) {
        try {
            val request = Request.Builder().url(url).get().build()
            val response = remoteClient.newCall(request).execute()
            if (!response.isSuccessful) {
                Log.w(TAG, "Mirror $url to local: download HTTP ${response.code}")
                return@withContext null
            }
            // Prefer the source server's Content-Type — it's the authoritative format
            // metadata; the relay's magic library can't detect MP4/MOV from bytes alone.
            val contentType = response.header("Content-Type") ?: "application/octet-stream"
            val data = readBodyCapped(response, MAX_BLOB_BYTES) ?: return@withContext null
            val sha256 = computeSHA256(data)
            if (saveToLocalRelay(data, sha256, contentType)) sha256 else null
        } catch (e: Exception) {
            Log.w(TAG, "Mirror $url to local failed: ${e.message}")
            null
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
     * What pushing one blob from this device's relay to the outside servers
     * did. "Pushed to mirrors" used to be shown whatever happened, including
     * when every server refused the upload.
     */
    sealed class MirrorPushResult {
        /** Every server tried accepted the blob. */
        data class AllAccepted(val count: Int) : MirrorPushResult()

        /** Some servers accepted it, some did not. */
        data class Partial(val accepted: Int, val attempted: Int) : MirrorPushResult()

        /** Every server tried refused it or could not be reached. */
        data class AllFailed(val attempted: Int) : MirrorPushResult()

        /** No outside server is configured (or none of the requested ones is). */
        data object NoOutsideServer : MirrorPushResult()

        /** The blob could not be read from this device's relay. */
        data object NotOnDevice : MirrorPushResult()

        /** The upload could not be signed. */
        data object SignerUnavailable : MirrorPushResult()

        /** At least one outside server now holds the blob. */
        val anyAccepted: Boolean get() = this is AllAccepted || this is Partial

        /** One short line for a toast. Wording follows iOS (PR #109). */
        val message: String
            get() = when (this) {
                is AllAccepted -> "Pushed to mirrors"
                is Partial -> "Mirrored to $accepted of $attempted Blossom servers"
                is AllFailed -> "Could not push to mirrors"
                NoOutsideServer -> "No Blossom mirrors configured"
                NotOnDevice -> "Could not read this file from your vault"
                SignerUnavailable -> "Could not sign the upload"
            }

        companion object {
            fun of(accepted: Int, attempted: Int): MirrorPushResult = when {
                attempted <= 0 -> NoOutsideServer
                accepted >= attempted -> AllAccepted(attempted)
                accepted > 0 -> Partial(accepted, attempted)
                else -> AllFailed(attempted)
            }
        }
    }

    /**
     * Push a blob that is already in this device's relay to the outside
     * servers. [only] limits the upload to those servers (the ones missing the
     * blob); null means every configured server. Port of iOS
     * `pushLocalToMirrors(sha256:only:)`.
     */
    suspend fun pushLocalToMirrors(sha256: String, only: Collection<String>? = null): MirrorPushResult =
        withContext(Dispatchers.IO) {
            val configured = configStore.config.value.activeBlossomMirrors
            val mirrors = if (only == null) configured else configured.filter { it in only }
            if (mirrors.isEmpty()) {
                Log.w(TAG, "Push of ${sha256.take(8)}: no outside Blossom server to push to")
                return@withContext MirrorPushResult.NoOutsideServer
            }

            val localUrl = localBlossomURL() ?: return@withContext MirrorPushResult.NotOnDevice

            // Read from this device's relay.
            var contentType = "application/octet-stream"
            val data = try {
                val request = Request.Builder().url("$localUrl/$sha256").get().build()
                localClient.newCall(request).execute().use { response ->
                    if (!response.isSuccessful) {
                        Log.w(TAG, "Push of ${sha256.take(8)}: local read HTTP ${response.code}")
                        return@withContext MirrorPushResult.NotOnDevice
                    }
                    response.header("Content-Type")?.takeIf { it.isNotBlank() }?.let { contentType = it }
                    readBodyCapped(response, MAX_BLOB_BYTES)
                } ?: return@withContext MirrorPushResult.NotOnDevice
            } catch (e: Exception) {
                Log.w(TAG, "Local download failed: ${e.message}")
                return@withContext MirrorPushResult.NotOnDevice
            }

            // Sign once and reuse across all mirrors (external signers fail on
            // concurrent signing requests).
            val authHeader = createAuthHeader("upload", sha256)
            if (authHeader.isEmpty()) {
                Log.e(TAG, "Push aborted: could not create Blossom auth event (signer unavailable)")
                return@withContext MirrorPushResult.SignerUnavailable
            }

            val accepted = mirrors.map { mirror ->
                async {
                    try {
                        uploadToServer(
                            source = UploadSource.Data(data),
                            serverUrl = mirror,
                            sha256 = sha256,
                            contentType = contentType,
                            authHeader = authHeader,
                        ) != null
                    } catch (e: Exception) {
                        Log.w(TAG, "Push to mirror $mirror failed: ${e.message}")
                        false
                    }
                }
            }.awaitAll().count { it }

            MirrorPushResult.of(accepted, mirrors.size).also {
                Log.i(TAG, "Push of ${sha256.take(8)}: $accepted of ${mirrors.size} servers accepted")
            }
        }

    /**
     * Mirror all blobs from external to local.
     * @return how many blobs were saved to the local relay.
     */
    suspend fun mirrorAllFromExternal(
        onProgress: ((Float) -> Unit)? = null,
        onLogMessage: ((String) -> Unit)? = null,
    ): Int = withContext(Dispatchers.IO) {
        val mirrors = configStore.config.value.activeBlossomMirrors
        val ownerPubkey = nostrService.ownerHexPubkey

        val allHashes = mutableSetOf<String>()

        // Sign ONE kind 24242 auth event for the ENTIRE mirror-in and reuse it for
        // both the remote /list and every local /upload. It carries both "t" verbs
        // (list + upload) and no "x", so the relay accepts it for either operation
        // (upload isn't bound to a blob hash; list matches the "list" verb). This is
        // a single signer round-trip — one Amber/NIP-46 prompt for the whole pull,
        // instead of one per mirror plus one per blob.
        val batchAuth = createAuthHeader(listOf("list", "upload"))

        // Fetch blob lists from each mirror
        for (mirror in mirrors) {
            try {
                val request = Request.Builder()
                    .url("$mirror/list/$ownerPubkey")
                    .get()
                    .apply { if (batchAuth.isNotEmpty()) addHeader("Authorization", "Nostr $batchAuth") }
                    .build()

                val response = remoteClient.newCall(request).execute()
                if (response.isSuccessful) {
                    val body = response.body?.string() ?: continue
                    val blobs = json.decodeFromString<List<BlobDescriptor>>(body)
                    blobs.mapNotNull { it.sha256 }.forEach { allHashes.add(it) }
                }
            } catch (e: Exception) {
                Log.w(TAG, "Blob list fetch from $mirror failed: ${e.message}")
            }
        }

        // Filter to hashes not in local Blossom
        val missing = allHashes.filter { !mediaCacheService.isInLocalBlossom(it) }
        onLogMessage?.invoke("Found ${missing.size} blobs to mirror")
        if (missing.isEmpty()) return@withContext 0
        if (batchAuth.isEmpty()) {
            onLogMessage?.invoke("Mirror aborted: could not sign auth event (signer unavailable)")
            return@withContext 0
        }

        val completed = java.util.concurrent.atomic.AtomicInteger(0)
        val saved = java.util.concurrent.atomic.AtomicInteger(0)
        coroutineScope {
            for (hash in missing) {
                mirrorSemaphore.acquire()
                launch {
                    try {
                        val data = downloadFromMirrors(hash)
                        if (data != null && saveToLocalRelay(data, hash, "application/octet-stream", batchAuth)) {
                            saved.incrementAndGet()
                        }
                    } finally {
                        mirrorSemaphore.release()
                        onProgress?.invoke(completed.incrementAndGet().toFloat() / missing.size)
                    }
                }
            }
        }
        saved.get()
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
        // Bare-hash file (how the relay stores blobs) is the common case.
        val exact = File(dir, sha256)
        if (exact.exists()) return exact.delete()

        // Otherwise delete any `<hash>.<ext>` variant, regardless of extension
        // (covers audio/documents, not just images/video).
        val matches = dir.listFiles { f -> f.isFile && f.nameWithoutExtension == sha256 }
        if (!matches.isNullOrEmpty()) {
            return matches.all { it.delete() }
        }
        return false
    }

    // ══════════════════════════════════════════════════════════════════
    // Mirror status
    // ══════════════════════════════════════════════════════════════════

    /**
     * Each server's last answer per blob, kept for the session. The Media tab
     * tiles, the list rows and the viewer all read this one map, so a file
     * cannot show "3/3" on its tile and offer a Mirror button in the viewer.
     */
    private val _mirrorPresence = kotlinx.coroutines.flow.MutableStateFlow<Map<String, Map<String, BlobPresence>>>(emptyMap())
    val mirrorPresence: kotlinx.coroutines.flow.StateFlow<Map<String, Map<String, BlobPresence>>> = _mirrorPresence

    /** Checks running now, by hash, so a grid of tiles asks each server once per blob. */
    private val presenceInFlight = mutableMapOf<String, Deferred<Map<String, BlobPresence>>>()

    /** Caps blobs checked at once; a scrolled grid would otherwise fire hundreds of HEADs. */
    private val presenceGate = kotlinx.coroutines.sync.Semaphore(6)

    /**
     * Check if a blob exists on each mirror. A server that could not be asked
     * counts as "does not have it" here; use [checkMirrorPresence] to tell the two apart.
     */
    suspend fun checkMirrorStatus(sha256: String): Map<String, Boolean> =
        checkMirrorPresence(sha256, force = true).mapValues { it.value == BlobPresence.PRESENT }

    /**
     * Asks every configured Blossom server whether it holds [sha256] and
     * records the answer in [mirrorPresence]. Without [force], a cached answer
     * that covers every configured server, or a check already running, is reused.
     * Port of iOS `BlossomBackupStore.refresh`.
     */
    suspend fun checkMirrorPresence(sha256: String, force: Boolean = false): Map<String, BlobPresence> {
        val hash = sha256.lowercase()
        val mirrors = configStore.config.value.activeBlossomMirrors
        if (mirrors.isEmpty()) return emptyMap()
        val running = synchronized(presenceInFlight) { presenceInFlight[hash] }
        if (running != null) {
            val result = running.await()
            if (!force) return result
        } else if (!force) {
            _mirrorPresence.value[hash]?.takeIf { cached -> mirrors.all { it in cached } }?.let { return it }
        }
        // The check runs in the service scope and records its own answer, so a
        // tile scrolled away mid-check still fills the cache for when it returns.
        val job = synchronized(presenceInFlight) {
            presenceInFlight[hash]?.takeIf { !force } ?: scope.async {
                try {
                    presenceGate.withPermit {
                        mirrors.map { mirror -> async { mirror to checkBlobExists(mirror, hash) } }
                            .awaitAll().toMap()
                    }.also { result -> _mirrorPresence.update { it + (hash to result) } }
                } finally {
                    synchronized(presenceInFlight) {
                        if (presenceInFlight[hash] === coroutineContext[Job]) presenceInFlight.remove(hash)
                    }
                }
            }.also { presenceInFlight[hash] = it }
        }
        return job.await()
    }

    /** Drops every cached answer, so the next look asks the servers again (pull to refresh). */
    fun forgetMirrorPresence() {
        _mirrorPresence.value = emptyMap()
    }

    /**
     * How many configured servers hold [sha256], or null until every one of
     * them has answered once.
     */
    fun backupSummary(sha256: String, presence: Map<String, Map<String, BlobPresence>> = _mirrorPresence.value): BlossomBackupSummary? =
        BlossomBackupSummary.of(presence[sha256.lowercase()], configStore.config.value.activeBlossomMirrors)

    /**
     * A 2xx alone is not enough: some servers answer 200 with an HTML page for
     * any path, which would read as "has it" for every file.
     */
    private fun checkBlobExists(mirror: String, sha256: String): BlobPresence {
        return try {
            val request = Request.Builder()
                .url("${mirror.trimEnd('/')}/$sha256")
                .head()
                .build()
            val client = if (isLocalhost(mirror)) localClient else presenceClient
            client.newCall(request).execute().use { response ->
                blobPresence(response.code, response.header("Content-Type"), response.header("Content-Length"))
            }
        } catch (e: Exception) {
            BlobPresence.UNREACHABLE
        }
    }

    /** Short timeouts: a sleeping server should read as "couldn't reach", not hang the badge. */
    private val presenceClient by lazy {
        remoteClient.newBuilder()
            .connectTimeout(10, TimeUnit.SECONDS)
            .readTimeout(10, TimeUnit.SECONDS)
            .build()
    }

    // ══════════════════════════════════════════════════════════════════
    // Auth header generation
    // ══════════════════════════════════════════════════════════════════

    /**
     * Create a Blossom auth header (kind 24242 signed event as base64).
     */
    private suspend fun createAuthHeader(
        operation: String,
        sha256: String? = null,
        uploadUrl: String? = null,
    ): String = createAuthHeader(listOf(operation), sha256, uploadUrl)

    /**
     * Create a Blossom auth header that authorizes several operations at once by
     * carrying one "t" tag per verb (e.g. ["list", "upload"]). The relay matches
     * the request's verb against any present "t" tag, so a single signed event —
     * and therefore a single signer round-trip — can cover the whole mirror-in
     * (remote /list + local /upload). Critical for external signers (Amber/NIP-46
     * bunker) that prompt per signature.
     */
    private suspend fun createAuthHeader(
        operations: List<String>,
        sha256: String? = null,
        uploadUrl: String? = null,
    ): String {
        val expiration = (System.currentTimeMillis() / 1000) + 3600 // 1 hour (matches iOS)
        val tags = mutableListOf<List<String>>()
        operations.forEach { tags.add(listOf("t", it)) }
        // The "x" tag scopes auth to a specific blob; list/server-wide ops carry
        // no hash (matches iOS BUD-02 /list auth).
        sha256?.let { tags.add(listOf("x", it)) }
        tags.add(listOf("expiration", expiration.toString()))
        uploadUrl?.let { tags.add(listOf("u", it)) }

        val label = operations.joinToString("+")
        // Use signEventAsync so external signers (Amber NIP-55, NIP-46) work.
        // The synchronous signEvent only handles a locally-stored key and returns
        // null under Amber (no on-device key) → empty auth header → servers reject
        // with "missing auth event" / 401. signEventAsync routes to the active
        // signing mode (amber/nip46/local).
        //
        // Retry a failed signature instead of failing the whole upload on the
        // first miss. Under Amber a signature is another app being launched and
        // brought to the front, so a single failure is ordinary — Amber not
        // resumed yet, slow to start, or a prompt dismissed by a stray tap. One
        // miss used to kill the post; the user would repost and it would work,
        // which is exactly the symptom iOS had before it grew the same retry
        // (BlossomService.swift makeUploadAuth, 3 attempts 1s apart).
        var event: NostrEvent? = null
        for (attempt in 1..AUTH_SIGN_ATTEMPTS) {
            event = try {
                nostrService.signEventAsync(
                    kind = AUTH_KIND,
                    content = if (sha256 != null) "Blossom $label ${sha256.take(8)}" else "Blossom $label",
                    tags = tags,
                    forceOwner = true,
                )
            } catch (e: SignerRejectedException) {
                // The user was asked and said no. Retrying would just re-prompt.
                Log.w(TAG, "Blossom auth signing declined by the user ($label)")
                return ""
            } catch (e: Exception) {
                Log.e(TAG, "Blossom auth signing failed ($label): ${e.message}")
                null
            }
            if (event != null) break
            Log.w(TAG, "Blossom auth signing returned no event ($label) — attempt $attempt/$AUTH_SIGN_ATTEMPTS")
            if (attempt < AUTH_SIGN_ATTEMPTS) delay(AUTH_SIGN_RETRY_DELAY_MS)
        }
        if (event == null) return ""

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
    // Utilities
    // ══════════════════════════════════════════════════════════════════

    /** Embedded relay's Blossom, or the external one when that mode is on (null if unset). */
    fun localBlossomURL(): String? = configStore.config.value.localBlossomBaseURL

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

/** Whether one Blossom server holds a blob. */
enum class BlobPresence {
    PRESENT,
    ABSENT,
    /** The server did not answer (offline, timeout, 5xx), so we do not know. */
    UNREACHABLE,
}

/** The decision behind a HEAD check, split out so it can be tested without a server. Matches iOS. */
fun blobPresence(statusCode: Int, contentType: String?, contentLength: String?): BlobPresence = when (statusCode) {
    in 200..299 -> when {
        contentType?.lowercase()?.startsWith("text/html") == true -> BlobPresence.ABSENT
        contentLength?.toLongOrNull() == 0L -> BlobPresence.ABSENT
        else -> BlobPresence.PRESENT
    }
    in 400..499 -> BlobPresence.ABSENT
    else -> BlobPresence.UNREACHABLE
}

/** How many of the user's Blossom servers hold one file. Port of iOS `BlossomBackupSummary`. */
data class BlossomBackupSummary(
    val present: Int,
    val unreachable: Int,
    val total: Int,
    /** Servers not known to have the file: those that said no plus those that could not be asked. */
    val missing: List<String>,
) {
    val isComplete: Boolean get() = total > 0 && present == total
    /** Worth offering an upload: some server lacks it, or could not be asked. */
    val needsMirror: Boolean get() = total > 0 && present < total

    companion object {
        /** Null while any configured server has no answer yet, rather than guessing. */
        fun of(byMirror: Map<String, BlobPresence>?, mirrors: List<String>): BlossomBackupSummary? {
            if (mirrors.isEmpty()) return BlossomBackupSummary(0, 0, 0, emptyList())
            if (byMirror == null || !mirrors.all { it in byMirror }) return null
            var present = 0
            var unreachable = 0
            val missing = mutableListOf<String>()
            for (mirror in mirrors) {
                when (byMirror[mirror]) {
                    BlobPresence.PRESENT -> present++
                    BlobPresence.UNREACHABLE -> { unreachable++; missing += mirror }
                    else -> missing += mirror
                }
            }
            return BlossomBackupSummary(present, unreachable, mirrors.size, missing)
        }
    }
}
