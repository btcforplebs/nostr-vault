package com.nostrvault.service

import com.nostrvault.relay.vaultMediaServers
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.async
import kotlinx.coroutines.awaitAll
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.withContext
import okhttp3.Request
import java.io.File

/**
 * "Delete from this device" (D3, plan RESEARCH/NV_MEDIA_LIST_SIZE_2026_11_26.md §4): removes this phone's vault
 * copy of one file and keeps it on the servers. The file goes only after a fresh check proves another place holds
 * the same bytes ([DeleteHereGate]), and it goes on the owner's "removed here" list first ([DeviceRemovedStore]) so
 * Auto-Mirror, the note-media pass and the engine never pull it back. iOS twin `BlossomService+DeleteHere.swift`.
 */
sealed interface DeleteHereResult {
    data class Deleted(val holders: List<String>) : DeleteHereResult
    data class Refused(val why: String) : DeleteHereResult
    data class Failed(val why: String) : DeleteHereResult
}

/** The vault folder and its owner, for the "removed here" list; null before setup. */
internal fun BlossomService.removedHereScope(): Pair<File, String>? {
    val config = configStore.config.value
    val dir = config.relayDataDir?.let { File(it, config.blossomPath) } ?: return null
    return dir to nostrService.ownerHexPubkey
}

/** [hashes] without the ones removed from this device. */
internal fun BlossomService.withoutRemovedHere(hashes: List<String>): List<String> {
    val (vault, owner) = removedHereScope() ?: return hashes
    return DeviceRemovedStore.list(owner, vault).keeping(hashes)
}

/** The list now (for a pass that checks many files). */
internal fun BlossomService.removedHereList(): DeviceRemovedHashes =
    removedHereScope()?.let { (vault, owner) -> DeviceRemovedStore.list(owner, vault) } ?: DeviceRemovedHashes()

/** An explicit Save to Vault of [sha256]: it may come back. */
internal fun BlossomService.clearRemovedHere(sha256: String) {
    val (vault, owner) = removedHereScope() ?: return
    DeviceRemovedStore.remove(sha256, owner, vault)
}

suspend fun BlossomService.deleteHere(sha256: String): DeleteHereResult = withContext(Dispatchers.IO) {
    val hash = sha256.lowercase()
    if (!MediaSizeCache.isHash(hash)) return@withContext DeleteHereResult.Refused("This isn't a vault file.")
    val (vault, owner) = removedHereScope() ?: return@withContext DeleteHereResult.Refused("This file isn't on this device.")
    val file = File(vault, hash).takeIf { it.isFile }
        ?: vault.listFiles { f -> f.isFile && f.nameWithoutExtension.lowercase() == hash }?.firstOrNull()
    val size = file?.length() ?: 0L
    if (file == null || size <= 0) return@withContext DeleteHereResult.Refused("This file isn't on this device.")

    // On a phone the owner's Mac or box is a real second copy (Logen, 2026-11-27). A mesh name can't be asked over HTTP.
    val config = configStore.config.value
    val servers = (config.activeBlossomMirrors + config.vaultMediaServers)
        .filterNot { runCatching { java.net.URI(it).host?.lowercase()?.endsWith(".fips") }.getOrNull() == true }
    val candidates = DeleteHereGate.candidates(servers, ownHosts = emptySet())

    // Asked now, every one, no cached answer.
    val answers = coroutineScope {
        candidates.map { server -> async { server to deleteHereProbe(server, hash) } }.awaitAll().toMap()
    }
    when (val decision = DeleteHereGate.decide(answers, hash, size)) {
        is DeleteHereGate.Decision.Refused -> return@withContext DeleteHereResult.Refused(decision.why)
        is DeleteHereGate.Decision.Allowed -> {
            // On the list before the file goes, so a run starting now skips it.
            if (!DeviceRemovedStore.add(hash, owner, vault)) {
                return@withContext DeleteHereResult.Failed("Couldn't save the list of files removed here, so nothing was deleted.")
            }
            // Nothing still queued sends it on (as deleteFromLocal).
            homeVault.forgetBlob(hash)
            if (!file.delete()) {
                DeviceRemovedStore.remove(hash, owner, vault)
                return@withContext DeleteHereResult.Failed("Couldn't remove the file from this device.")
            }
            DeleteHereResult.Deleted(decision.holders)
        }
    }
}

/**
 * One server's headers for `GET <server>/<hash>` with `Range: bytes=0-0` (a GET, not HEAD: some servers keep
 * answering HEAD for blobs they have dropped). Null when it could not be asked.
 */
private fun BlossomService.deleteHereProbe(server: String, sha256: String): DeleteHereGate.Answer? = runCatching {
    val base = server.trimEnd('/')
    val request = Request.Builder().url("$base/$sha256").get()
        .header("Range", "bytes=0-0").header("Cache-Control", "no-cache").build()
    presenceClient.newCall(request).execute().use { r ->
        DeleteHereGate.Answer(r.code, r.header("Content-Type"), r.header("Content-Length"), r.header("Content-Range"), r.request.url.toString())
    }
}.getOrNull()
