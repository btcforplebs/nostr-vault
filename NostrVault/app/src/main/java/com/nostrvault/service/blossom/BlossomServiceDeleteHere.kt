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
 * - this device's own relay never counts: loopback and `.fips` hosts are left
 *   out, and every vault copy of the file is moved out of the vault folder
 *   while the servers are asked, so no name this device answers under
 *   (tunnel, LAN name, Tailscale) can prove its own copy (Tron M1);
 * - the owner's Mac or box counts as a safe copy, like any media server
 *   (Logen 2026-11-27; Apple twin BlossomService+DeleteHere.swift on iOS);
 * - a server counts only when it answers present AND serves this file's
 *   length (some keep answering for a blob they dropped), not from a cache;
 * - the hash goes on the "removed here" list ([DeviceRemovedHashes]) before
 *   the file is deleted, so Auto-Mirror cannot pull it back; no save, no delete.
 */
suspend fun BlossomService.deleteFromThisDevice(sha256: String): DeleteHereResult = withContext(Dispatchers.IO) {
    val hash = sha256.lowercase()
    if (!AutoMirrorRules.isHash(hash)) return@withContext DeleteHereResult.NotHere
    val files = vaultFiles(hash)
    if (files.isEmpty()) return@withContext DeleteHereResult.NotHere
    val length = files.first().length()
    if (length <= 0) return@withContext DeleteHereResult.NotHere

    val owner = nostrService.ownerHexPubkey
    if (owner.isBlank()) return@withContext DeleteHereResult.Kept(DELETE_HERE_NO_COPY)
    val config = configStore.config.value
    val published = nostrService.serverLists.value[owner].orEmpty()
    val servers = config.blossomDeleteTargets(published, photoUrl = null, includeHomeVault = true)
        .filterNot(::isThisDeviceAddress)
        // Asked over https only, like iOS DeleteHereGate.probeURL: a plain-http
        // answer on the LAN can come from anyone on the Wi-Fi (Tron, #2658).
        .mapNotNull(::httpsOnly)
        .distinct()

    if (servers.isEmpty()) return@withContext DeleteHereResult.Kept(DELETE_HERE_NO_COPY)
    val asideDir = deleteHereAsideDir() ?: return@withContext DeleteHereResult.Kept(DELETE_HERE_NO_SAVE)
    if (!deleteHereInFlight.add(hash)) return@withContext DeleteHereResult.Kept(DELETE_HERE_NO_SAVE)
    try {
        restoreDeleteHereAside()
        // Listed first, so Auto-Mirror can't pull it back while it is out of the vault.
        val wasListed = removedHere.isRemoved(owner, hash)
        if (!removedHere.markRemoved(owner, hash)) return@withContext DeleteHereResult.Kept(DELETE_HERE_NO_SAVE)
        // A quit mid-check must put the list back as it was: note whom to unlist (Tron low 3).
        val mark = File(File(asideDir, MARKS), hash)
        // Listed already: clear any stale mark a quit left behind, or recovery would unlist it.
        val marked = if (wasListed) mark.delete() || !mark.exists()
        else runCatching { mark.parentFile?.mkdirs(); mark.writeText(owner) }.isSuccess
        // Every `<hash>` / `<hash>.<ext>` copy out of the vault folder (Tron low 2). Not
        // renamed in place: the engine serves `<hash>.<any ext>` (haven-go load_blob.go).
        val moved = mutableListOf<Pair<File, File>>()
        fun putBack(): Boolean {
            val back = moved.all { (from, to) -> to.renameTo(from) }
            if (back) {
                if (!wasListed) removedHere.unmark(owner, hash)
                mark.delete()
            }
            return back
        }
        val allAside = marked && files.all { f ->
            val to = File(asideDir, f.name)
            asideDir.mkdirs()
            f.renameTo(to).also { if (it) moved += f to to }
        }
        if (!allAside) {
            putBack()
            return@withContext DeleteHereResult.Kept("Couldn't remove the file from this device.")
        }
        val heldBy = servers.map { server -> async { heldCopyProbe(server, hash, length) } }.awaitAll().count { it }
        if (heldBy == 0) {
            val back = putBack()
            Log.i(BlossomService.TAG, "Delete here ${hash.take(8)}: kept, 0 of ${servers.size} servers hold it (back=$back)")
            return@withContext DeleteHereResult.Kept(DELETE_HERE_NO_COPY)
        }
        homeVault.forgetBlob(hash)
        if (!moved.all { (_, to) -> to.delete() || !to.exists() }) {
            putBack()
            return@withContext DeleteHereResult.Kept("Couldn't remove the file from this device.")
        }
        mark.delete()
        // Anything that landed in the vault meanwhile.
        deleteFromLocal(hash)
        Log.i(BlossomService.TAG, "Delete here ${hash.take(8)}: removed, $heldBy server(s) hold it")
        DeleteHereResult.Removed(length, heldBy)
    } finally {
        deleteHereInFlight.remove(hash)
    }
}

/** [server] as https: http becomes https (it then fails closed without TLS), anything else is dropped. */
private fun httpsOnly(server: String): String? = when {
    server.startsWith("https://", ignoreCase = true) -> server
    server.startsWith("http://", ignoreCase = true) -> "https://" + server.substring("http://".length)
    else -> null
}

/** Loopback: this device's own relay under its plainest name. */
private fun isThisDeviceAddress(server: String): Boolean {
    val host = runCatching { java.net.URI(server).host?.lowercase()?.trim('[', ']') }.getOrNull() ?: return true
    return host == "localhost" || host == "0.0.0.0" || host == "::1" || host.startsWith("127.")
}

/** Hashes a "Delete from this device" is checking right now (their files are aside). */
private val deleteHereInFlight: MutableSet<String> = java.util.concurrent.ConcurrentHashMap.newKeySet()

/** Per hash, the account to take it off the list for if a check never finishes. */
private const val MARKS = "unlist"

/** Where a file waits, outside the vault folder, while the servers are asked. */
internal fun BlossomService.deleteHereAsideDir(): File? =
    configStore.config.value.relayDataDir?.let { File(it, "removed_here_aside") }

/**
 * Puts back any file left aside by a check that never finished (the app
 * quit mid-check), and the list as it was before that check: unlisted only if
 * the check listed it. Runs at start and before each delete; skips checks still running.
 */
internal fun BlossomService.restoreDeleteHereAside() {
    val asideDir = deleteHereAsideDir() ?: return
    val config = configStore.config.value
    val vault = config.relayDataDir?.let { File(it, config.blossomPath) } ?: return
    val left = asideDir.listFiles { f -> f.isFile } ?: return
    val done = mutableSetOf<String>()
    for (f in left) {
        val hash = f.name.substringBefore('.').lowercase()
        if (hash in deleteHereInFlight) continue
        vault.mkdirs()
        val target = File(vault, f.name)
        // Never a recursive delete here (Tron, #2657): the aside copy goes only when the
        // vault already holds the same name at the same length; otherwise it stays for next time.
        val ok = if (target.exists()) target.length() == f.length() && f.delete() else f.renameTo(target)
        Log.i(BlossomService.TAG, "Delete here ${hash.take(8)}: put back after an unfinished check (ok=$ok)")
        if (ok) done += hash
    }
    for (hash in done) {
        if (asideDir.listFiles { f -> f.isFile && f.name.substringBefore('.').lowercase() == hash }?.isNotEmpty() == true) continue
        val mark = File(File(asideDir, MARKS), hash)
        mark.takeIf { it.isFile }?.readText()?.trim()?.takeIf { it.isNotEmpty() }?.let { removedHere.unmark(it, hash) }
        mark.delete()
    }
}

/** The vault file for [hash]: the bare-hash name the relay uses, else `<hash>.<ext>`. */
internal fun BlossomService.vaultFile(hash: String): File? = vaultFiles(hash).firstOrNull()

/** Every vault copy of [hash]: `<hash>` first, then each `<hash>.<ext>`. */
internal fun BlossomService.vaultFiles(hash: String): List<File> {
    val config = configStore.config.value
    val dir = config.relayDataDir?.let { File(it, config.blossomPath) } ?: return emptyList()
    val exact = File(dir, hash).takeIf { it.isFile }
    val others = dir.listFiles { f -> f.isFile && f.name != hash && f.nameWithoutExtension == hash }.orEmpty().sortedBy { it.name }
    return listOfNotNull(exact) + others
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
