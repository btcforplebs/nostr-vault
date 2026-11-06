package com.nostrvault.service

import android.util.Log
import com.nostrvault.service.BlossomService.Companion.MESH_DELETE_PATIENCE_MS
import com.nostrvault.service.BlossomService.Companion.TAG
import kotlinx.coroutines.delay
import okhttp3.Request
import java.io.IOException

    /**
     * BUD-02 DELETE of [sha256] on the owner's device [npub] over the mesh, through the loopback
     * ingress the reader and [com.nostrvault.fips.HomeVaultSender] use, then a HEAD to see it gone
     * ([com.nostrvault.fips.MeshDeleteTargets.gone]). Right after the engine starts the link is
     * still coming up and resets the first tries, so a dropped connection is retried for
     * [MESH_DELETE_PATIENCE_MS]. The ingress URL carries a token: logged by npub only.
     */
    internal suspend fun BlossomService.deleteOverMesh(npub: String, sha256: String, auth: String): Boolean {
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
                val checkCode = remoteClient.newCall(com.nostrvault.fips.VaultCheck.request(base, sha256, auth))
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
