package com.nostrvault.service

import android.util.Log
import com.nostrvault.service.BlossomService.Companion.TAG
import com.nostrvault.service.BlossomService.UploadSource
import okhttp3.OkHttpClient
import okhttp3.Request

/**
 * BUD-06: before sending a file to an outside server, ask whether it takes it (`HEAD /upload` with the file's hash,
 * size and type). Only a real "not this file" (too big, wrong type, not allowed) stops the upload; a server without
 * the route (404/405), one that can't answer now (5xx, 408, 429) or one that can't be reached gets the upload anyway,
 * as on iPhone/Mac (`preflightCheck`). NDK check step 3, Logen 2026-11-04.
 */
object UploadPreflight {
    /** Whether an answer [code] to `HEAD /upload` lets the upload go ahead. */
    fun allows(code: Int): Boolean = when {
        code in 200..299 -> true
        code == 404 || code == 405 -> true // no BUD-06 here: just upload
        code >= 500 || code == 408 || code == 429 -> true // didn't answer the question
        else -> false
    }
}

internal fun UploadSource.byteCount(): Long = when (this) {
    is UploadSource.Data -> data.size.toLong()
    is UploadSource.FileSource -> file.length()
}

/**
 * Asks [serverUrl] whether it takes this blob. A refusal is recorded with the server's reason ([BlossomRefusals]) and
 * returns false; anything else returns true.
 */
internal fun uploadPreflight(
    client: OkHttpClient,
    serverUrl: String,
    sha256: String,
    contentType: String,
    size: Long,
    auth: String,
): Boolean = try {
    val request = Request.Builder()
        .url("$serverUrl/upload")
        .head()
        .addHeader("X-SHA-256", sha256)
        .addHeader("X-Content-Length", size.toString())
        .addHeader("X-Content-Type", contentType)
        .addHeader("Authorization", "Nostr $auth")
        .build()
    client.newCall(request).execute().use { response ->
        if (UploadPreflight.allows(response.code)) {
            true
        } else {
            val reason = response.header("X-Reason")
            BlossomRefusals.record(sha256, serverUrl, response.code, reason)
            Log.i(TAG, "BUD-06: $serverUrl refused ${sha256.take(8)} — HTTP ${response.code}: ${reason ?: "no reason"}")
            false
        }
    }
} catch (e: Exception) {
    Log.w(TAG, "BUD-06: preflight to $serverUrl failed (${e.message}) — uploading anyway")
    true
}
