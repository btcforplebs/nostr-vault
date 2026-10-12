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
) {
    companion object {
        val copied = CopyAttempt(BlobCopyOutcome.Copied)
        fun failed(reason: String, retry: Boolean = false, authRefused: Boolean = false) =
            CopyAttempt(BlobCopyOutcome.Failed(reason), retry, authRefused)
    }
}

/** How long signing may take before the copy gives up on it. */
private const val COPY_SIGN_LIMIT_MS = 45_000L

/**
 * Copy clients: a minute without a byte moving is a stall, and one file gets
 * 15 minutes at most. The upload client allows 10 minutes of write silence,
 * three tries a file, which is how a copy could sit on one file for half an hour.
 */
private val copyClients = mutableMapOf<OkHttpClient, OkHttpClient>()

private fun copyClient(base: OkHttpClient): OkHttpClient = synchronized(copyClients) {
    copyClients.getOrPut(base) {
        base.newBuilder()
            .connectTimeout(20, TimeUnit.SECONDS)
            .writeTimeout(60, TimeUnit.SECONDS)
            .readTimeout(60, TimeUnit.SECONDS)
            .callTimeout(15, TimeUnit.MINUTES)
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
 * a copy that sat still while the signer did not answer. Blossom servers
 * match the `x` tag they need among all of them (khatru:
 * `FindWithValue("x", hash)`); one that refuses gets a single-file signature,
 * see [copyStoredBlob]. Null when the signer gave nothing in time.
 */
suspend fun BlossomService.makeBatchUploadAuth(hashes: List<String>): String? {
    if (hashes.isEmpty()) return null
    val expiration = System.currentTimeMillis() / 1000 + 3 * 3600
    val tags = listOf(listOf("t", "upload")) + hashes.map { listOf("x", it) } +
        listOf(listOf("expiration", expiration.toString()))
    val content = if (hashes.size == 1) "Blossom upload ${hashes[0].take(8)}" else "Blossom upload of ${hashes.size} files"
    Log.i(TAG, "copy: asking the signer for one upload authorisation covering ${hashes.size} file(s)")
    val event = try {
        withTimeoutOrNull(COPY_SIGN_LIMIT_MS) {
            nostrService.signEventAsync(kind = AUTH_KIND, content = content, tags = tags, forceOwner = true)
        }
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
 * turns it down, the file is signed on its own.
 */
suspend fun BlossomService.copyStoredBlob(
    sha256: String,
    file: File,
    servers: List<String>,
    batchAuth: String? = null,
): Map<String, BlobCopyOutcome> = withContext(Dispatchers.IO) {
    val tag = sha256.take(8)
    fun all(outcome: BlobCopyOutcome) = servers.associateWith { outcome }
    if (servers.isEmpty()) return@withContext emptyMap()
    val size = file.length()
    if (!file.isFile || size <= 0L) {
        Log.w(TAG, "copy $tag: the file is no longer on this phone")
        return@withContext all(BlobCopyOutcome.Failed("This file is no longer on this phone."))
    }
    val contentType = sniffContentType(file)
    Log.i(TAG, "copy $tag ($size bytes, $contentType) to ${servers.joinToString()}")

    suspend fun ownAuth(): String? = withTimeoutOrNull(COPY_SIGN_LIMIT_MS) {
        createAuthHeader("upload", sha256).ifEmpty { null }
    }
    val auth = batchAuth ?: ownAuth()
        ?: return@withContext all(BlobCopyOutcome.Failed(signerProblem()))

    servers.map { server ->
        async {
            var attempt = putStoredBlob(file, size, sha256, contentType, server, auth)
            // One more try for the failures that tend to pass: a server
            // error, a dropped connection, a stall.
            if (attempt.worthRetry && isActive) {
                delay(2_000)
                attempt = putStoredBlob(file, size, sha256, contentType, server, auth)
            }
            // A server that wants exactly one hash per signature.
            if (attempt.authRefused && batchAuth != null && isActive) {
                ownAuth()?.let { single -> attempt = putStoredBlob(file, size, sha256, contentType, server, single) }
            }
            when (val outcome = attempt.outcome) {
                BlobCopyOutcome.Copied -> Log.i(TAG, "copy $tag to $server: done")
                is BlobCopyOutcome.Failed -> Log.w(TAG, "copy $tag to $server failed: ${outcome.reason}")
            }
            server to attempt.outcome
        }
    }.awaitAll().toMap()
}

private fun BlossomService.putStoredBlob(
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
        copyClient(clientFor(base)).newCall(request).execute().use { response ->
            if (response.isSuccessful) return CopyAttempt.copied
            val said = response.header("X-Reason") ?: response.body?.string()?.take(200)?.trim()
            copyFailure(response.code, said)
        }
    } catch (e: Exception) {
        if (e is CancellationException) throw e
        copyFailure(e)
    }
}

internal fun copyFailure(status: Int, serverSays: String?): CopyAttempt {
    val said = serverSays?.takeIf { it.isNotBlank() && !it.startsWith("<") }
    val suffix = said?.let { " It said: \"$it\"." } ?: ""
    return when (status) {
        401, 403 -> CopyAttempt.failed("The server turned down your key (HTTP $status).$suffix", authRefused = true)
        402 -> CopyAttempt.failed("The server wants payment to store files (HTTP 402).$suffix")
        409 -> CopyAttempt.failed("The server already has a different file under this name (HTTP 409).$suffix")
        413 -> CopyAttempt.failed("Too big for this server (HTTP 413).$suffix")
        415 -> CopyAttempt.failed("The server doesn't take this type of file (HTTP 415).$suffix")
        429 -> CopyAttempt.failed("The server asked us to slow down (HTTP 429). Try again in a minute.", retry = true)
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
    is IOException -> if (error.message?.contains("Canceled", ignoreCase = true) == true) {
        CopyAttempt.failed("Stopped.")
    } else {
        CopyAttempt.failed("The connection dropped.", retry = true)
    }
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
