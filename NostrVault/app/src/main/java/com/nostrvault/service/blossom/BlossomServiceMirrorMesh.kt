package com.nostrvault.service

import com.nostrvault.fips.MeshMirrorResult
import com.nostrvault.fips.MeshMirrorSend
import com.nostrvault.fips.offerMirror
import java.io.File

/**
 * The feed Mirror's mesh step, after the vault and the media servers: offer the blob in this phone's vault
 * ([file]) to each of the owner's mesh devices their kind 10063 lists as `fipsmesh://<npub>/` (Logen
 * 2026-11-11). No 10063 entry, no mesh send. Signed with this device's mesh key only ([MeshMirrorSend]).
 */
suspend fun BlossomService.mirrorToMesh(sha256: String, contentType: String, file: File?): List<MeshMirrorResult> {
    if (file == null || !file.exists()) return emptyList()
    val owner = nostrService.ownerHexPubkey.takeIf { it.isNotEmpty() } ?: return emptyList()
    val listed = MeshMirrorSend.listedNpubs(nostrService.serverLists.value[owner].orEmpty())
    if (listed.isEmpty()) return emptyList()
    return homeVault.offerMirror(sha256, contentType, file, listed)
}

/** Ask for the owner's 10063 if it has not been read yet, so a Mirror tap knows which mesh devices it lists. */
fun BlossomService.loadOwnerServerList() {
    val owner = nostrService.ownerHexPubkey.takeIf { it.isNotEmpty() } ?: return
    if (owner !in nostrService.serverLists.value) nostrService.fetchServerList(owner)
}
