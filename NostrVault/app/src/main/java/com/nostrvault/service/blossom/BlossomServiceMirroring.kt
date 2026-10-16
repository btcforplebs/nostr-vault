package com.nostrvault.service

import android.util.Base64
import android.util.Log
import kotlinx.coroutines.*
import kotlinx.serialization.json.*
import okhttp3.*
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.RequestBody.Companion.asRequestBody
import com.nostrvault.service.BlossomService.Companion.AUTH_KIND
import com.nostrvault.service.BlossomService.Companion.TAG
import com.nostrvault.service.BlossomService.MirrorPushResult
import java.io.File
import java.io.IOException
import java.net.ConnectException
import java.net.SocketTimeoutException
import java.net.UnknownHostException
import java.util.concurrent.TimeUnit
import javax.net.ssl.SSLException

    /**
     * Uploads a blob already on this phone to the servers not known to have
     * it, then re-checks so badges show the new count. Null when every server
     * already had it. Port of iOS `MediaBackupActions.mirrorMissing`.
     */
    suspend fun BlossomService.pushToMissing(sha256: String): MirrorPushResult? {
        checkMirrorPresence(sha256, force = true)
        val summary = backupSummary(sha256)
        if (summary != null && !summary.needsMirror) return null
        val result = pushLocalToMirrors(sha256, only = summary?.missing)
        checkMirrorPresence(sha256, force = true)
        return result
    }

// ══════════════════════════════════════════════════════════════════
// Copy a stored file to servers (Media servers › Copy to servers)
// ══════════════════════════════════════════════════════════════════

/** How sending one file to one server went, in words a person can act on. */
sealed interface BlobCopyOutcome {
    data object Copied : BlobCopyOutcome
    data class Failed(val reason: String) : BlobCopyOutcome
}

/** One PUT's result, and whether the failure is the kind that passes. */
internal data class CopyAttempt(
    val outcome: BlobCopyOutcome,
    val worthRetry: Boolean = false,
    val authRefused: Boolean = false,
    /** The HTTP status of a refusal, so the run can tell 401 from 403. */
    val status: Int? = null,
) {
    companion object {
        val copied = CopyAttempt(BlobCopyOutcome.Copied)
        fun failed(reason: String, retry: Boolean = false, authRefused: Boolean = false, status: Int? = null) =
            CopyAttempt(BlobCopyOutcome.Failed(reason), retry, authRefused, status)
    }
}

/**
 * What one copy run has learned about each server, so a server that turns the
 * key down is asked once, not once a file with a new signature each time.
 *
 * Only a refusal of the key counts: a 401, or a 403 for two different files.
 * One 403 can be about that file alone (its type, its content), and marking
 * the server for it would fail every later file with that file's reason.
 */
class BlobCopyRun {
    private val refused = mutableMapOf<String, String>()
    private val forbidden = mutableMapOf<String, MutableSet<String>>()
    private val singleOnly = mutableSetOf<String>()

    /** The reason a server gave when it refused the key for this run. */
    @Synchronized fun refusal(server: String): String? = refused[server]

    /** A server turned down a one-file signature for [hash]. */
    @Synchronized fun noteRefusal(server: String, hash: String, status: Int?, reason: String) {
        if (status == 403) {
            val files = forbidden.getOrPut(server) { mutableSetOf() }.apply { add(hash) }
            if (files.size < 2) return
        }
        refused[server] = reason
    }
    /** A server that took a one-file signature after turning down the batch one. */
    @Synchronized fun wantsSingle(server: String): Boolean = server in singleOnly
    @Synchronized fun markWantsSingle(server: String) { singleOnly += server }
}

/**
 * Copy clients: 150 s with no byte moving is a stall, either way. That also
 * covers the wait after the last byte, while a server works on a big file
 * before it answers. No cap on a whole upload, so a big video on a slow line
 * keeps going while bytes move. The upload client allows 10 minutes of write
 * silence, three tries a file, which is how a copy could sit on one file for
 * half an hour.
 */
private val copyClients = mutableMapOf<OkHttpClient, OkHttpClient>()

private fun copyClient(base: OkHttpClient): OkHttpClient = synchronized(copyClients) {
    copyClients.getOrPut(base) {
        base.newBuilder()
            .connectTimeout(20, TimeUnit.SECONDS)
            .writeTimeout(150, TimeUnit.SECONDS)
            .readTimeout(150, TimeUnit.SECONDS)
            .callTimeout(0, TimeUnit.MILLISECONDS)
            .build()
    }
}

/** The file for [sha256] in this phone's vault folder, bare hash or `<hash>.<ext>`. */
fun BlossomService.localBlobFile(sha256: String): File? {
    val config = configStore.config.value
    val dir = config.relayDataDir?.let { File(it, config.blossomPath) } ?: return null
    File(dir, sha256).takeIf { it.isFile }?.let { return it }
    return dir.listFiles { f -> f.isFile && f.nameWithoutExtension.equals(sha256, ignoreCase = true) }?.firstOrNull()
}

/**
 * One upload authorisation for several files: an `x` tag per hash. Signing
 * one per file meant a signer round trip (and maybe a prompt) per file, and
 * a copy that sat still while the signer did not answer. BUD-11 lets an
 * authorisation carry several `x` tags; on `PUT /upload` the server needs one
 * that matches `X-SHA-256`. A server that refuses it gets a single-file
 * signature, see [copyStoredBlob]. No time limit of our own: the signer has
 * one, and an approval that comes late must still count. Null when the signer
 * gave nothing.
 */
suspend fun BlossomService.makeBatchUploadAuth(hashes: List<String>): String? {
    if (hashes.isEmpty()) return null
    val expiration = System.currentTimeMillis() / 1000 + 3 * 3600
    val tags = listOf(listOf("t", "upload")) + hashes.map { listOf("x", it) } +
        listOf(listOf("expiration", expiration.toString()))
    val content = if (hashes.size == 1) "Blossom upload ${hashes[0].take(8)}" else "Blossom upload of ${hashes.size} files"
    Log.i(TAG, "copy: asking the signer for one upload authorisation covering ${hashes.size} file(s)")
    val event = try {
        nostrService.signEventAsync(kind = AUTH_KIND, content = content, tags = tags, forceOwner = true)
    } catch (e: CancellationException) {
        throw e
    } catch (e: Exception) {
        Log.w(TAG, "copy: signing failed: ${e.message}")
        null
    } ?: run {
        Log.w(TAG, "copy: the signer gave no upload authorisation")
        return null
    }
    return Base64.encodeToString(eventJson(event).toByteArray(), Base64.NO_WRAP)
}

internal fun eventJson(event: NostrEvent): String = buildJsonObject {
    put("id", event.id)
    put("pubkey", event.pubkey)
    put("created_at", event.createdAt)
    put("kind", event.kind)
    putJsonArray("tags") { event.tags.forEach { tag -> addJsonArray { tag.forEach { add(it) } } } }
    put("content", event.content)
    put("sig", event.sig)
}.toString()

/** Why signing failed, in the words for the signer this account uses. */
fun BlossomService.signerProblem(): String = when (configStore.config.value.activeSigningMode()) {
    "nip46", "amber" -> "Your signer didn't answer. Open it, approve the request if it asks, then tap Retry."
    else -> "Couldn't sign with your key. If it's locked with a password, unlock it, then tap Retry."
}

/**
 * Sends a file stored on this phone to each of [servers], streaming it from
 * disk, and says what happened at each one. [batchAuth] is a shared
 * authorisation from [makeBatchUploadAuth]; without one, or when a server
 * turns it down, the file is signed on its own, once for all servers. [run]
 * remembers across files which servers refuse the key outright, so they are
 * not sent to the signer again. Stop cancels the uploads in flight.
 */
suspend fun BlossomService.copyStoredBlob(
    sha256: String,
    file: File,
    servers: List<String>,
    batchAuth: String? = null,
    run: BlobCopyRun = BlobCopyRun(),
): Map<String, BlobCopyOutcome> = withContext(Dispatchers.IO) {
    val tag = sha256.take(8)
    if (servers.isEmpty()) return@withContext emptyMap()
    val size = file.length()
    if (!file.isFile || size <= 0L) {
        Log.w(TAG, "copy $tag: the file is no longer on this phone")
        return@withContext servers.associateWith { BlobCopyOutcome.Failed("This file is no longer on this phone.") }
    }
    val contentType = sniffContentType(file)
    Log.i(TAG, "copy $tag ($size bytes, $contentType) to ${servers.joinToString()}")

    val results = mutableMapOf<String, BlobCopyOutcome>()
    val viaBatch = mutableListOf<String>()
    val viaSingle = mutableListOf<String>()
    for (server in servers) {
        val refused = run.refusal(server)
        when {
            refused != null -> results[server] = BlobCopyOutcome.Failed(refused)
            batchAuth != null && !run.wantsSingle(server) -> viaBatch += server
            else -> viaSingle += server
        }
    }

    suspend fun send(targets: List<String>, auth: String): Map<String, CopyAttempt> = coroutineScope {
        targets.map { server ->
            async {
                var attempt = putStoredBlob(file, size, sha256, contentType, server, auth)
                // One more try for the failures that tend to pass: a server
                // error, a dropped connection, a stall.
                if (attempt.worthRetry) {
                    delay(2_000)
                    attempt = putStoredBlob(file, size, sha256, contentType, server, auth)
                }
                server to attempt
            }
        }.awaitAll().toMap()
    }

    if (batchAuth != null && viaBatch.isNotEmpty()) {
        for ((server, attempt) in send(viaBatch, batchAuth)) {
            // Maybe a server that wants exactly one hash per signature.
            if (attempt.authRefused) viaSingle += server else results[server] = attempt.outcome
        }
    }
    if (viaSingle.isNotEmpty()) {
        // The file's own signature, asked for once whatever the number of servers.
        val single = createAuthHeader("upload", sha256).ifEmpty { null }
        if (single == null) {
            Log.w(TAG, "copy $tag: could not sign the upload")
            val reason = BlobCopyOutcome.Failed(signerProblem())
            viaSingle.forEach { results[it] = reason }
        } else {
            for ((server, attempt) in send(viaSingle, single)) {
                results[server] = attempt.outcome
                val outcome = attempt.outcome
                if (attempt.authRefused && outcome is BlobCopyOutcome.Failed) {
                    // Maybe it refuses the key itself: not on its list,
                    // unpaid. Then no more signatures for it this run.
                    run.noteRefusal(server, sha256, attempt.status, outcome.reason)
                } else if (batchAuth != null && outcome == BlobCopyOutcome.Copied) {
                    run.markWantsSingle(server)
                }
            }
        }
    }

    results.forEach { (server, outcome) ->
        when (outcome) {
            BlobCopyOutcome.Copied -> Log.i(TAG, "copy $tag to $server: done")
            is BlobCopyOutcome.Failed -> Log.w(TAG, "copy $tag to $server failed: ${outcome.reason}")
        }
    }
    results
}

private suspend fun BlossomService.putStoredBlob(
    file: File,
    size: Long,
    sha256: String,
    contentType: String,
    server: String,
    auth: String,
): CopyAttempt {
    var base = server.trimEnd('/')
    val local = isLocalhost(base) || com.nostrvault.data.remote.WebSocketClient.isLocalOrLanHost(base)
    if (base.startsWith("http://") && !local) base = "https://" + base.removePrefix("http://")
    val request = try {
        Request.Builder()
            .url("$base/upload")
            .put(file.asRequestBody(contentType.toMediaType()))
            .header("Authorization", "Nostr $auth")
            .header("Content-Type", contentType)
            .header("X-SHA-256", sha256)
            .build()
    } catch (e: IllegalArgumentException) {
        return CopyAttempt.failed("This server address isn't valid.")
    }
    return try {
        copyClient(clientFor(base)).newCall(request).await().use { response ->
            if (response.isSuccessful) {
                // A website that answers every PUT with its home page has not
                // stored anything (see BlossomUploadReply).
                val reply = response.body?.string()
                if (BlossomUploadReply.hostedUrl(reply, base, sha256, BlossomUploadReply.isOnDevice(base)) == null) {
                    return CopyAttempt.failed("This address answered, but not as a Blossom media server. For nostr.build, use https://blossom.nostr.build.")
                }
                return CopyAttempt.copied
            }
            val said = response.header("X-Reason") ?: response.body?.string()?.take(200)?.trim()
            copyFailure(response.code, said)
        }
    } catch (e: Exception) {
        if (e is CancellationException) throw e
        copyFailure(e)
    }
}

/**
 * Runs the call without blocking, and cancels it when the coroutine is
 * cancelled: Stop cuts off an upload in flight instead of waiting it out.
 */
private suspend fun Call.await(): Response = suspendCancellableCoroutine { cont ->
    cont.invokeOnCancellation { cancel() }
    enqueue(object : Callback {
        override fun onResponse(call: Call, response: Response) {
            if (cont.isActive) cont.resumeWith(Result.success(response)) else response.close()
        }
        override fun onFailure(call: Call, e: IOException) {
            if (cont.isActive) cont.resumeWith(Result.failure(e))
        }
    })
}

internal fun copyFailure(status: Int, serverSays: String?): CopyAttempt {
    val said = serverSays?.takeIf { it.isNotBlank() && !it.startsWith("<") }
    val suffix = said?.let { " It said: \"$it\"." } ?: ""
    return when (status) {
        401, 403 -> CopyAttempt.failed("The server turned down your key (HTTP $status).$suffix", authRefused = true, status = status)
        402 -> CopyAttempt.failed("The server wants payment to store files (HTTP 402).$suffix")
        409 -> CopyAttempt.failed("The server already has a different file under this name (HTTP 409).$suffix")
        413 -> CopyAttempt.failed("Too big for this server (HTTP 413).$suffix")
        415 -> CopyAttempt.failed("The server doesn't take this type of file (HTTP 415).$suffix")
        // Shown only after the retry two seconds later was turned down too.
        429 -> CopyAttempt.failed("The server asked us to slow down (HTTP 429). Wait a minute, then tap Retry.", retry = true)
        in 500..599 -> CopyAttempt.failed("The server had a problem (HTTP $status). Try again later.$suffix", retry = true)
        else -> CopyAttempt.failed("The server said no (HTTP $status).$suffix")
    }
}

internal fun copyFailure(error: Exception): CopyAttempt = when (error) {
    is UnknownHostException -> CopyAttempt.failed("Couldn't find the server's address.")
    is SocketTimeoutException -> CopyAttempt.failed("The server stopped answering.", retry = true)
    is ConnectException -> CopyAttempt.failed("The server isn't answering.", retry = true)
    is SSLException -> CopyAttempt.failed("Couldn't make a secure connection to the server.")
    is java.io.FileNotFoundException -> CopyAttempt.failed("This file is no longer on this phone.")
    is IOException -> CopyAttempt.failed("The connection dropped.", retry = true)
    else -> CopyAttempt.failed(error.message ?: "Something went wrong.", retry = true)
}

/**
 * The type to send, from the file's first bytes: the stored name has no
 * extension, and "application/octet-stream" makes some servers serve a photo
 * as a download.
 */
fun sniffContentType(file: File): String {
    val head = try {
        file.inputStream().use { input -> ByteArray(16).let { buf -> buf.copyOf(input.read(buf).coerceAtLeast(0)) } }
    } catch (e: IOException) {
        return "application/octet-stream"
    }
    return sniffContentType(head)
}

internal fun sniffContentType(head: ByteArray): String {
    fun at(offset: Int, bytes: ByteArray) =
        head.size >= offset + bytes.size && head.copyOfRange(offset, offset + bytes.size).contentEquals(bytes)
    fun text(offset: Int, ascii: String) = at(offset, ascii.toByteArray(Charsets.US_ASCII))
    fun bytes(offset: Int, vararg values: Int) = at(offset, ByteArray(values.size) { values[it].toByte() })
    return when {
        bytes(0, 0xFF, 0xD8, 0xFF) -> "image/jpeg"
        bytes(0, 0x89, 0x50, 0x4E, 0x47) -> "image/png"
        text(0, "GIF8") -> "image/gif"
        text(0, "RIFF") && text(8, "WEBP") -> "image/webp"
        text(4, "ftyp") -> when {
            text(8, "qt  ") -> "video/quicktime"
            text(8, "heic") || text(8, "heix") || text(8, "mif1") -> "image/heic"
            text(8, "avif") -> "image/avif"
            text(8, "M4A ") -> "audio/mp4"
            else -> "video/mp4"
        }
        bytes(0, 0x1A, 0x45, 0xDF, 0xA3) -> "video/webm"
        text(0, "ID3") || bytes(0, 0xFF, 0xFB) -> "audio/mpeg"
        text(0, "%PDF") -> "application/pdf"
        else -> "application/octet-stream"
    }
}
