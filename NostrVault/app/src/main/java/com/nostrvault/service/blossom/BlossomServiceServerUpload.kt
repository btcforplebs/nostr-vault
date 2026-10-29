package com.nostrvault.service

import android.util.Log
import kotlinx.coroutines.*
import kotlinx.serialization.json.*
import okhttp3.*
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.RequestBody.Companion.asRequestBody
import okhttp3.RequestBody.Companion.toRequestBody
import java.io.IOException
import com.nostrvault.service.BlossomService.Companion.MAX_UPLOAD_RETRIES
import com.nostrvault.service.BlossomService.Companion.TAG
import com.nostrvault.service.BlossomService.UploadSource

    /**
     * Uploads to every mirror at once and returns the link from the first that
     * accepts the blob. The post doesn't wait for the rest: they finish in the
     * background ([BlossomService.scope]). Same as iOS `firstHostingMirror`.
     */
    internal suspend fun BlossomService.mirrorUploadPass(
        source: UploadSource,
        mirrors: List<String>,
        sha256: String,
        contentType: String,
        authHeader: String,
    ): String? {
        // The stragglers outlive this call, so they read their own link to a
        // file source: callers delete their temp file once the post is out.
        var raceFile: java.io.File? = null
        val raceSource = (source as? UploadSource.FileSource)?.let { fileSource ->
            val link = java.io.File(fileSource.file.parentFile, "mirror-race-${java.util.UUID.randomUUID()}")
            val linked = try {
                java.nio.file.Files.createLink(link.toPath(), fileSource.file.toPath()); true
            } catch (e: Exception) {
                try { fileSource.file.copyTo(link); true } catch (e2: Exception) { false }
            }
            if (linked) { raceFile = link; UploadSource.FileSource(link) } else null
        } ?: source
        val jobs: List<suspend () -> String?> = mirrors.map { mirrorUrl ->
            suspend {
                try {
                    uploadToServer(
                        source = raceSource,
                        serverUrl = mirrorUrl,
                        sha256 = sha256,
                        contentType = contentType,
                        authHeader = authHeader,
                    )
                } catch (e: Exception) {
                    if (e is CancellationException) throw e
                    Log.w(TAG, "Mirror to $mirrorUrl failed: ${e.message}")
                    null
                }
            }
        }
        return FirstAnswer.first(scope, jobs, onLate = { index, url ->
            if (url != null) Log.i(TAG, "Background mirror ok — ${mirrors[index]} also has ${sha256.take(8)}")
        }, onAllDone = { raceFile?.delete() })
    }

    /** A server that can't be found, refuses or never answers won't on a second try either. */
    internal fun isWorthRetrying(error: Exception): Boolean = when (error) {
        is java.net.UnknownHostException, is java.net.ConnectException,
        is java.net.SocketTimeoutException, is java.net.NoRouteToHostException -> false
        else -> true
    }

    // ══════════════════════════════════════════════════════════════════
    // Remote server upload
    // ══════════════════════════════════════════════════════════════════

    /**
     * Upload to a specific server with retry logic.
     */
    suspend fun BlossomService.uploadToServer(
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
                    // An outside server must hand back a BUD-02 blob descriptor;
                    // a bare 200 (a website's home page) is not an upload.
                    val reply = response.use { it.body?.string() }
                    BlossomUploadReply.hostedUrl(reply, serverUrl, sha256, BlossomUploadReply.isOnDevice(serverUrl))
                        ?.let { return@withContext it }
                    Log.w(TAG, "Mirror $serverUrl answered HTTP ${response.code} without a blob descriptor " +
                        "(${BlossomUploadReply.describe(reply, response.header("Content-Type"))}) — not a Blossom server address?")
                    return@withContext null
                }

                val errorBody = response.body?.string()?.take(500) ?: ""
                Log.w(TAG, "Mirror $serverUrl returned HTTP ${response.code}: $errorBody")
                lastError = IOException("HTTP ${response.code}: $errorBody")
                BlossomRefusals.record(sha256, serverUrl, response.code)
                // The server refuses this file (too big, payment, forbidden):
                // sending all of it again gets the same answer.
                if (com.nostrvault.data.model.MediaPostRetry.isPermanentRefusal(response.code)) {
                    return@withContext null
                }

                if (attempt < MAX_UPLOAD_RETRIES - 1) {
                    delay(1000L * (attempt + 1)) // Linear backoff
                }
            } catch (e: Exception) {
                if (e is CancellationException) throw e
                lastError = e
                if (!isWorthRetrying(e)) {
                    Log.w(TAG, "Upload to $serverUrl failed: ${e.message}")
                    return@withContext null
                }
                if (attempt < MAX_UPLOAD_RETRIES - 1) {
                    delay(1000L * (attempt + 1))
                }
            }
        }

        Log.w(TAG, "Upload to $serverUrl failed after $MAX_UPLOAD_RETRIES attempts: ${lastError?.message}")
        null
    }
