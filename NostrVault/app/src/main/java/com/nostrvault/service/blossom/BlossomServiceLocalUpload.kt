package com.nostrvault.service

import android.util.Log
import kotlinx.coroutines.*
import kotlinx.serialization.json.*
import okhttp3.*
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.RequestBody.Companion.asRequestBody
import okhttp3.RequestBody.Companion.toRequestBody
import java.io.File
import com.nostrvault.service.BlossomService.Companion.TAG
import com.nostrvault.service.BlossomService.UploadSource

    /**
     * Send a blob that is already in this device's relay to the outside
     * servers, returning the URL of the first that accepts it. What
     * `MediaPostQueue` calls when it retries a waiting post. One pass only —
     * the queue itself is the retry.
     */
    suspend fun BlossomService.hostLocalBlob(sha256: String, contentType: String): String? = withContext(Dispatchers.IO) {
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
                clientFor(localBase).newCall(request).execute().use { response ->
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

    // ══════════════════════════════════════════════════════════════════
    // Local relay upload
    // ══════════════════════════════════════════════════════════════════

    suspend fun BlossomService.saveToLocalRelay(data: ByteArray, sha256: String, contentType: String, authHeader: String? = null): Boolean {
        val url = localBlossomURL() ?: return false
        return try {
            val auth = authHeader ?: createAuthHeader("upload", sha256)
            val request = Request.Builder()
                .url("$url/upload")
                .put(data.toRequestBody(contentType.toMediaType()))
                .addHeader("Authorization", "Nostr $auth")
                .addHeader("Content-Type", contentType)
                .build()

            val client = clientFor(url)
            client.newCall(request).execute().use { it.isSuccessful }
        } catch (e: Exception) {
            Log.w(TAG, "Local upload failed: ${e.message}")
            false
        }
    }

    suspend fun BlossomService.saveToLocalRelay(fileURL: File, sha256: String, contentType: String, authHeader: String? = null): Boolean {
        val url = localBlossomURL() ?: return false
        return try {
            val auth = authHeader ?: createAuthHeader("upload", sha256)
            val request = Request.Builder()
                .url("$url/upload")
                .put(fileURL.asRequestBody(contentType.toMediaType()))
                .addHeader("Authorization", "Nostr $auth")
                .addHeader("Content-Type", contentType)
                .build()

            val client = clientFor(url)
            client.newCall(request).execute().use { it.isSuccessful }
        } catch (e: Exception) {
            Log.w(TAG, "Local file upload failed: ${e.message}")
            false
        }
    }
