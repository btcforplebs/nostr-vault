package com.nostrvault.service

import android.util.Log
import com.nostrvault.service.BlossomService.Companion.MESH_DELETE_PATIENCE_MS
import com.nostrvault.fips.MeshKeyAuth
import com.nostrvault.fips.MeshKeySigner
import com.nostrvault.service.BlossomService.Companion.TAG
import kotlinx.coroutines.delay
import okhttp3.Request
import java.io.IOException

/**
 * The tokens for one Delete everywhere over the mesh, signed by this device's own mesh key, never the owner's
 * (docs/MESH_COPY_V2_CONTRACT.md §2.1; Logen, 2026-11-19: fail closed): one delete naming every target in `p`, and one
 * get for the HEAD checks. Twin of Apple `BlossomService+MeshDelete.swift`.
 */
internal class MeshDeleteAuth(val device: String?, val deviceCheck: String?) {
    companion object {
        fun of(sha256: String, receivers: List<String>) = MeshDeleteAuth(
            device = MeshKeySigner.blossom(MeshKeyAuth.Verb.DELETE, listOf(sha256), receivers, "Delete blob ${sha256.take(8)}..."),
            deviceCheck = MeshKeySigner.blossom(MeshKeyAuth.Verb.GET, listOf(sha256), receivers, "Check blob ${sha256.take(8)}..."),
        )
    }
}

    /**
     * [deleteOverMesh] on [npub] with this device's mesh key. Without a mesh key here, or for a vault that turns it
     * down, the file stays and the device is listed as failed. True when the file is gone.
     */
    internal suspend fun BlossomService.deleteOnMeshDevice(npub: String, sha256: String, auth: MeshDeleteAuth): Boolean {
        val device = auth.device ?: run {
            Log.e(TAG, "Mesh delete: this device has no mesh key yet")
            return false
        }
        return deleteOverMesh(npub, sha256, device, auth.deviceCheck)
    }

    /**
     * BUD-02 DELETE of [sha256] on the owner's device [npub] over the mesh, through the loopback
     * ingress the reader and [com.nostrvault.fips.HomeVaultSender] use, then a HEAD to see it gone
     * ([com.nostrvault.fips.MeshDeleteTargets.gone]). Right after the engine starts the link is
     * still coming up and resets the first tries, so a dropped connection is retried for
     * [MESH_DELETE_PATIENCE_MS]. The ingress URL carries a token: logged by npub only.
     */
    internal suspend fun BlossomService.deleteOverMesh(npub: String, sha256: String, auth: String, checkAuth: String?): Boolean {
        val deadline = System.currentTimeMillis() + MESH_DELETE_PATIENCE_MS
        while (true) {
            val base = meshIngress(npub) ?: run {
                Log.w(TAG, "Mesh delete ${npub.take(12)}: vault not reachable")
                return false
            }
            try {
                val deleteCode = remoteClient.newCall(
                    Request.Builder().url("$base/$sha256").delete()
                        .header("Authorization", "Nostr $auth").build()
                ).execute().use { it.code }
                val checkCode = remoteClient.newCall(com.nostrvault.fips.VaultCheck.request(base, sha256, checkAuth))
                    .execute().use { it.code }
                val gone = com.nostrvault.fips.MeshDeleteTargets.gone(deleteCode, checkCode)
                if (!gone) Log.w(TAG, "Mesh delete ${npub.take(12)}: DELETE $deleteCode, then HEAD $checkCode")
                return gone
            } catch (e: IOException) {
                meshForget(npub)
                if (System.currentTimeMillis() + meshRetryDelayMs > deadline) {
                    Log.w(TAG, "Mesh delete ${npub.take(12)} failed: ${e.message}")
                    return false
                }
                delay(meshRetryDelayMs)
            }
        }
    }
