package com.nostrvault.service

import kotlinx.coroutines.*
import kotlinx.serialization.json.*
import okhttp3.*

    /**
     * Whether a saved answer can stand in for asking: every configured server
     * is in it and every one of them answered. A "could not ask" is asked again.
     */
    internal fun reusablePresence(cached: Map<String, BlobPresence>, mirrors: List<String>): Boolean =
        mirrors.all { mirror -> cached[mirror].let { it != null && it != BlobPresence.UNREACHABLE } }

    /**
     * A 2xx alone is not enough: some servers answer 200 with an HTML page for
     * any path, which would read as "has it" for every file.
     */
    internal fun BlossomService.checkBlobExists(mirror: String, sha256: String): BlobPresence {
        return try {
            // Not HEAD: after a delete, blossom.band and blossom.nostr.build keep
            // answering HEAD with the old size, while a GET redirects to a "404"
            // placeholder image served as 200. A GET shows where the blob really
            // ends up; only its headers are read, never the body.
            val request = Request.Builder()
                .url("${mirror.trimEnd('/')}/$sha256")
                .get()
                .header("Range", "bytes=0-0")
                .build()
            val client = if (isLocalhost(mirror)) localClient else presenceClient
            client.newCall(request).execute().use { response ->
                blobPresence(
                    response.code, response.header("Content-Type"), response.header("Content-Length"),
                    sha256 = sha256, finalUrl = response.request.url.toString(),
                )
            }
        } catch (e: Exception) {
            BlobPresence.UNREACHABLE
        }
    }
