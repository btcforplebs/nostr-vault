package com.nostrvault.service

import android.util.Log
import com.nostrvault.relay.HavenBridge
import com.nostrvault.service.BlossomService.Companion.TAG
import okhttp3.Response
import java.io.File
import java.io.InputStream
import java.security.MessageDigest
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.Semaphore
import java.util.concurrent.atomic.AtomicBoolean

/**
 * Big media into the vault without holding it in memory (Logen, 2026-11-06:
 * eight 61-612 MB videos on the Moto were refused at the old 50 MB cap, and
 * the phone has under 1 GB free RAM, so raising the cap on the old
 * read-it-all path would have killed the app).
 *
 * A download goes straight to a temp file through one small buffer, hashed on
 * the way, and the vault takes it from that file ([storeStreamed]). There is
 * no size cap: a file is refused only when the disk can't hold it twice (the
 * temp file plus the vault's copy). The temp file is deleted on any failure,
 * and after the store.
 */
internal class StreamedBlob(
    val file: File,
    val sha256: String,
    val size: Long,
    /** Held for a big file until it is stored ([BigFileGate]); given back by [delete]. */
    private val gate: BigFileGate? = null,
) {
    private val done = AtomicBoolean(false)

    fun delete() {
        file.delete()
        BlobStream.forget(file)
        if (done.compareAndSet(false, true)) gate?.give()
    }
}

/**
 * Big files go one at a time (Tron's review of #1818): four big downloads in
 * parallel could each pass the space check and then abort each other at the
 * re-check, so none landed. A big file holds this from its first byte until
 * the vault has it; the waiting ones are told [StreamResult.Busy] and retry.
 */
internal class BigFileGate {
    private val permit = Semaphore(1)

    fun tryTake(): Boolean = permit.tryAcquire()

    fun give() = permit.release()

    /** Blocks until the big file ahead is done (without holding the turn). */
    fun waitTurn() {
        permit.acquire()
        permit.release()
    }

    companion object {
        val shared = BigFileGate()
    }
}

internal sealed interface StreamResult {
    data class Ok(val blob: StreamedBlob) : StreamResult

    /** Not stored; [reason] says why, for the log and the import summary. */
    data class Skipped(val reason: String) : StreamResult

    /** Another big file is on its way in: wait ([BigFileGate.waitTurn]) and ask again. Nothing kept. */
    data object Busy : StreamResult
}

internal object BlobStream {
    /** The one buffer a download uses. */
    const val BUFFER_BYTES = 64 * 1024

    /** Kept free on top of the two copies, so the import never fills the disk (as on iOS, 4c766919). */
    const val SPACE_MARGIN_BYTES = 256L * 1024 * 1024

    /** Re-check the disk this often when the server named no length. */
    private const val SPACE_RECHECK_BYTES = 16L * 1024 * 1024

    /** The disk can take a file of [size] twice (temp + vault) and keep the margin. */
    fun hasRoomFor(size: Long, freeBytes: Long): Boolean = freeBytes >= 2 * size + SPACE_MARGIN_BYTES

    fun skippedForSpace(size: Long, freeBytes: Long): StreamResult.Skipped =
        StreamResult.Skipped("$NO_ROOM: needs ${mb(2 * size + SPACE_MARGIN_BYTES)} MB, has ${mb(freeBytes)} MB")

    const val NO_ROOM = "not enough free storage"

    /** Above this a file is big: one at a time ([BigFileGate]). */
    const val BIG_BYTES = 50L * 1024 * 1024

    /** Temp files of this run's downloads; anything else named import-*.blob is a leftover. */
    private val live = ConcurrentHashMap.newKeySet<String>()

    fun forget(file: File) {
        live.remove(file.absolutePath)
    }

    /** Where downloads land: the app's private cache. */
    fun tempDir(): File = File(System.getProperty("java.io.tmpdir") ?: ".")

    /**
     * Deletes temp files a killed import left behind (Android kills the app
     * mid-import under low memory; each could hold hundreds of MB and shrink
     * the space the next import sees). Downloads still running are kept.
     * @return how many were deleted.
     */
    fun sweepLeftovers(dir: File = tempDir()): Int =
        dir.listFiles { f -> f.isFile && f.name.startsWith("import-") && f.name.endsWith(".blob") }
            .orEmpty()
            .count { it.absolutePath !in live && it.delete() }

    private fun mb(bytes: Long) = bytes / (1024 * 1024)

    /**
     * Streams [input] into a new temp file in [dir], hashing as it goes.
     * [declaredLength] is the server's Content-Length (-1 when unknown): with
     * it, the disk is checked before the first byte; without it, every
     * [SPACE_RECHECK_BYTES] against what has arrived so far. [expectSha]: the
     * bytes must hash to it (a mirror is content-addressed). Closes [input].
     */
    fun toTempFile(
        input: InputStream,
        declaredLength: Long,
        dir: File,
        expectSha: String? = null,
        freeBytes: () -> Long = { dir.usableSpace },
        gate: BigFileGate = BigFileGate.shared,
    ): StreamResult = input.use { stream ->
        var holding = false
        if (declaredLength > BIG_BYTES) {
            if (!gate.tryTake()) return StreamResult.Busy
            holding = true
        }
        if (declaredLength >= 0 && !hasRoomFor(declaredLength, freeBytes())) {
            if (holding) gate.give()
            return skippedForSpace(declaredLength, freeBytes())
        }
        val temp = try {
            File.createTempFile("import-", ".blob", dir).also { live.add(it.absolutePath) }
        } catch (e: Exception) {
            if (holding) gate.give()
            throw e
        }
        var kept = false
        try {
            val digest = MessageDigest.getInstance("SHA-256")
            val buffer = ByteArray(BUFFER_BYTES)
            var total = 0L
            var nextCheck = SPACE_RECHECK_BYTES
            temp.outputStream().use { out ->
                while (true) {
                    val n = stream.read(buffer)
                    if (n == -1) break
                    digest.update(buffer, 0, n)
                    out.write(buffer, 0, n)
                    total += n
                    // No length given: it becomes big here, so it takes its turn now or retries later.
                    if (!holding && total > BIG_BYTES) {
                        if (!gate.tryTake()) return StreamResult.Busy
                        holding = true
                    }
                    if (declaredLength >= 0 && total > declaredLength) {
                        return StreamResult.Skipped("server sent more than its Content-Length")
                    }
                    if (total >= nextCheck) {
                        nextCheck += SPACE_RECHECK_BYTES
                        // What is on disk already counts as the temp copy; the vault needs as much again.
                        if (freeBytes() < total + SPACE_MARGIN_BYTES) return skippedForSpace(total, freeBytes() + total)
                    }
                }
            }
            if (declaredLength >= 0 && total != declaredLength) {
                return StreamResult.Skipped("download cut short ($total of $declaredLength bytes)")
            }
            // The temp copy is on disk now; the vault's copy and the margin must still fit.
            if (freeBytes() < total + SPACE_MARGIN_BYTES) return skippedForSpace(total, freeBytes() + total)
            val sha = digest.digest().joinToString("") { "%02x".format(it) }
            if (expectSha != null && sha != expectSha.lowercase()) {
                return StreamResult.Skipped("bytes do not match their sha256")
            }
            kept = true
            return StreamResult.Ok(StreamedBlob(temp, sha, total, gate.takeIf { holding }))
        } finally {
            if (!kept) {
                temp.delete()
                forget(temp)
                if (holding) gate.give()
            }
        }
    }

    /**
     * Where the vault takes a streamed file from. Keyless always goes
     * in-process (it can't sign). A big file on this phone's own vault goes
     * in-process too: an HTTP PUT to the engine in this process makes it hold
     * the whole body in memory before storing (khatru). A small signed file,
     * or one for an external relay, is uploaded from the file over HTTP.
     */
    fun storesInProcess(keyless: Boolean, externalRelay: Boolean, size: Long): Boolean =
        keyless || (!externalRelay && size > IN_MEMORY_UPLOAD_MAX_BYTES)

    /**
     * Hands [blob] to the vault ([inProcess] by path when [viaEngine], else
     * [overHttp]) and deletes the temp file whatever happens.
     */
    suspend fun store(
        blob: StreamedBlob,
        contentType: String,
        viaEngine: Boolean,
        inProcess: (String, String, String) -> Boolean,
        overHttp: suspend () -> Boolean,
    ): Boolean = try {
        if (viaEngine) inProcess(blob.file.absolutePath, blob.sha256, contentType) else overHttp()
    } catch (e: Exception) {
        false
    } finally {
        blob.delete()
    }

    /** Above this an upload to this phone's own engine would sit in its memory. The old cap. */
    const val IN_MEMORY_UPLOAD_MAX_BYTES = 50L * 1024 * 1024
}

/** Downloads [response]'s body to a temp file in the cache dir (see [BlobStream.toTempFile]). */
internal fun BlossomService.streamToTempFile(response: Response, expectSha: String? = null): StreamResult {
    val body = response.body ?: return StreamResult.Skipped("empty response")
    return try {
        BlobStream.toTempFile(body.byteStream(), body.contentLength(), BlobStream.tempDir(), expectSha)
    } catch (e: Exception) {
        StreamResult.Skipped("download failed: ${e.message}")
    }
}

/**
 * Stores a streamed file in this device's vault and deletes the temp file.
 * [auth] is Import media's way in; null: a one-off save, signed with
 * [authHeader] or here when the HTTP path needs a signature.
 */
internal suspend fun BlossomService.storeStreamed(
    blob: StreamedBlob,
    contentType: String,
    auth: OwnVaultAuth?,
    authHeader: String? = null,
    inProcess: (String, String, String) -> Boolean = HavenBridge::importOwnerBlob,
): Boolean {
    val viaEngine = BlobStream.storesInProcess(auth == OwnVaultAuth.Keyless, configStore.config.value.useExternalRelay, blob.size)
    val sha = blob.sha256
    return BlobStream.store(blob, contentType, viaEngine, inProcess) {
        saveToLocalRelay(blob.file, blob.sha256, contentType, (auth as? OwnVaultAuth.Signed)?.header ?: authHeader)
    }.also { if (!it) Log.w(TAG, "Vault store of ${sha.take(8)} (${blob.size} bytes) failed") }
}
