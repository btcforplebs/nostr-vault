package com.nostrvault.service

import android.util.Log
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.async
import kotlinx.coroutines.awaitAll
import kotlinx.coroutines.withContext
import okhttp3.Request
import java.io.File

/** What "Delete from this device" did. */
sealed class DeleteHereResult {
    /** The vault file is gone; [heldBy] outside servers had it, checked just now. */
    data class Removed(val freedBytes: Long, val heldBy: Int) : DeleteHereResult()
    /** No vault file for this hash on this device. */
    data object NotHere : DeleteHereResult()
    /** Kept: no outside server proved it holds the file, or the mark could not be saved. */
    data class Kept(val reason: String) : DeleteHereResult()
}

internal const val DELETE_HERE_NO_COPY =
    "Kept on this device: none of your media servers has a copy right now."
internal const val DELETE_HERE_NO_SAVE = "Kept on this device: couldn't save the change. Try again."

/**
 * Removes this device's vault copy of [sha256] and keeps it on the media
 * servers. Fail closed, every step:
 * - the servers are asked now, never the day-old badge answers;
 * - only an outside server counts: never this device, the owner's Mac, box or
 *   any server the owner runs under another name ([serverOwner] must say
 *   OTHER), nor LAN, loopback or `.fips` hosts ([blossomDeleteTargets]);
 * - a server counts only when it answers present AND serves this file's
 *   length (some keep answering for a blob they dropped);
 * - the hash goes on the "removed here" list ([DeviceRemovedHashes]) before
 *   the file is deleted, so Auto-Mirror cannot pull it back; no save, no delete.
 */
suspend fun BlossomService.deleteFromThisDevice(sha256: String): DeleteHereResult = withContext(Dispatchers.IO) {
    val hash = sha256.lowercase()
    if (!AutoMirrorRules.isHash(hash)) return@withContext DeleteHereResult.NotHere
    val file = vaultFile(hash) ?: return@withContext DeleteHereResult.NotHere
    val length = file.length()
    if (length <= 0) return@withContext DeleteHereResult.NotHere

    val owner = nostrService.ownerHexPubkey
    if (owner.isBlank()) return@withContext DeleteHereResult.Kept(DELETE_HERE_NO_COPY)
    val config = configStore.config.value
    val published = nostrService.serverLists.value[owner].orEmpty()
    val servers = config.blossomDeleteTargets(published, photoUrl = null, includeHomeVault = false)

    val heldBy = servers.map { server ->
        async {
            serverOwner(server, owner) == BlossomService.ServerOwner.OTHER && heldCopyProbe(server, hash, length)
        }
    }.awaitAll().count { it }
    if (heldBy == 0) {
        Log.i(BlossomService.TAG, "Delete here ${hash.take(8)}: kept, 0 of ${servers.size} servers hold it")
        return@withContext DeleteHereResult.Kept(DELETE_HERE_NO_COPY)
    }
    if (!removedHere.markRemoved(owner, hash)) return@withContext DeleteHereResult.Kept(DELETE_HERE_NO_SAVE)
    if (!deleteFromLocal(hash)) return@withContext DeleteHereResult.Kept("Couldn't remove the file from this device.")
    Log.i(BlossomService.TAG, "Delete here ${hash.take(8)}: removed, $heldBy server(s) hold it")
    DeleteHereResult.Removed(length, heldBy)
}

/** The vault file for [hash]: the bare-hash name the relay uses, else `<hash>.<ext>`. */
internal fun BlossomService.vaultFile(hash: String): File? {
    val config = configStore.config.value
    val dir = config.relayDataDir?.let { File(it, config.blossomPath) } ?: return null
    File(dir, hash).takeIf { it.isFile }?.let { return it }
    return dir.listFiles { f -> f.isFile && f.nameWithoutExtension == hash }?.firstOrNull()
}

/** One server's answer for "Delete from this device": a 1-byte GET, its headers only. */
internal fun BlossomService.askServerHolds(server: String, hash: String, length: Long): Boolean = try {
    // A fresh query and no-cache: a CDN edge (Cloudflare keeps blobs 7 days) must not answer
    // for a blob the server already dropped (Tron, #2649).
    val bust = java.util.UUID.randomUUID().toString().take(12)
    val request = Request.Builder().url("${server.trimEnd('/')}/$hash?nvcheck=$bust").get()
        .header("Range", "bytes=0-0").header("Cache-Control", "no-cache").header("Pragma", "no-cache").build()
    presenceClient.newCall(request).execute().use { r ->
        deleteHereHolds(
            blobPresence(r.code, r.header("Content-Type"), r.header("Content-Length"), sha256 = hash, finalUrl = r.request.url.toString()),
            r.code, r.header("Content-Range"), r.header("Content-Length"), length,
            cacheStatus = r.header("cf-cache-status"), age = r.header("Age"),
        )
    }
} catch (e: Exception) {
    Log.w(BlossomService.TAG, "Delete here: $server: ${e.message}")
    false
}

/**
 * Whether one answer proves the server holds this file: present, and the size
 * it gives is [localLength] (`Content-Range: bytes 0-0/N` on 206, the length
 * of a whole-file 200), from the server itself, not a cache. No size given is not proof.
 */
internal fun deleteHereHolds(
    presence: BlobPresence,
    code: Int,
    contentRange: String?,
    contentLength: String?,
    localLength: Long,
    /** `cf-cache-status`: HIT, STALE or UPDATING came from the edge, not the server. */
    cacheStatus: String? = null,
    /** `Age` over 0: a cache answered. */
    age: String? = null,
): Boolean {
    if (presence != BlobPresence.PRESENT) return false
    if (cacheStatus?.trim()?.uppercase() in setOf("HIT", "STALE", "UPDATING")) return false
    if ((age?.trim()?.toLongOrNull() ?: 0L) > 0L) return false
    val total = when (code) {
        206 -> contentRange?.substringAfterLast('/', "")?.trim()?.toLongOrNull()
        200 -> contentLength?.trim()?.toLongOrNull()
        else -> null
    }
    return total != null && total == localLength
}
