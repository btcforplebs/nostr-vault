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
     * One concurrent upload pass over all mirrors; returns the URL from the
     * first mirror IN CONFIGURED ORDER that accepted the blob — not the first
     * to answer. The list order is the user's preference; fastest-first made
     * the posted link whichever server won the race that time. Same as iOS.
     */
    internal suspend fun BlossomService.mirrorUploadPass(
        source: UploadSource,
        mirrors: List<String>,
        sha256: String,
        contentType: String,
        authHeader: String,
    ): String? = coroutineScope {
        val jobs = mirrors.map { mirrorUrl ->
            async {
                try {
                    uploadToServer(
                        source = source,
                        serverUrl = mirrorUrl,
                        sha256 = sha256,
                        contentType = contentType,
                        authHeader = authHeader,
                    )
                } catch (e: Exception) {
                    Log.w(TAG, "Mirror to $mirrorUrl failed: ${e.message}")
                    null
                }
            }
        }
        jobs.awaitAll().firstOrNull { it != null }
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
