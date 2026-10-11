package com.nostrvault.service

import android.util.Log
import kotlinx.coroutines.*
import kotlinx.serialization.json.*
import okhttp3.*
import com.nostrvault.service.BlossomService.Companion.MAX_BLOB_BYTES
import com.nostrvault.service.BlossomService.Companion.TAG

    // ══════════════════════════════════════════════════════════════════
    // Download & mirroring
    // ══════════════════════════════════════════════════════════════════

    /**
     * Download from URL and save to local relay.
     */
    suspend fun BlossomService.downloadFromURL(url: String, mirrorToExternal: Boolean = false): ByteArray? {
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

    suspend fun BlossomService.downloadFromMirrors(sha256: String): ByteArray? {
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
     * Read a response body into memory with a hard byte ceiling.
     * Rejects up-front on an oversized Content-Length and aborts mid-stream if a
     * missing/lying length lets the body exceed [maxBytes]. Prevents a hostile or
     * broken server from OOM-killing the app with a giant blob.
     */
    internal fun BlossomService.readBodyCapped(response: Response, maxBytes: Long): ByteArray? {
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
