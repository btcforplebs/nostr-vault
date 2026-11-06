package com.nostrvault.service

import android.util.Log
import com.nostrvault.service.BlossomService.Companion.MESH_DELETE_PATIENCE_MS
import com.nostrvault.fips.MeshKeyAuth
import com.nostrvault.fips.MeshKeySigner
import com.nostrvault.service.BlossomService.Companion.TAG
import kotlinx.coroutines.delay
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import okhttp3.Request
import java.io.IOException

/** One mesh delete's answer: [gone], and whether the vault's refusal allows one try with the owner's token. */
internal data class MeshDeleteTry(val gone: Boolean, val ownerRetry: Boolean)

/**
 * The tokens for one Delete everywhere over the mesh, signed by this device's own mesh key, never the owner's
 * (docs/MESH_COPY_V2_CONTRACT.md §2.1): one delete naming every target in `p`, and one get for the HEAD checks. The
 * owner's token ([signOwner]) only for a vault that turns the device form down without X-Mesh-Devices, or with no mesh
 * key here: signed once, on first need. TODO(mesh-key): remove with the owner form. Twin of Apple
 * `BlossomService+MeshDelete.swift` (#1803).
 */
internal class MeshDeleteAuth(
    val device: String?,
    val deviceCheck: String?,
    private val signOwner: suspend () -> String?,
) {
    private val lock = Mutex()
    private var ownerTried = false
    private var ownerToken: String? = null

    suspend fun owner(): String? = lock.withLock {
        if (!ownerTried) { ownerTried = true; ownerToken = signOwner() }
        ownerToken
    }

    companion object {
        fun of(sha256: String, receivers: List<String>, signOwner: suspend () -> String?) = MeshDeleteAuth(
            device = MeshKeySigner.blossom(MeshKeyAuth.Verb.DELETE, listOf(sha256), receivers, "Delete blob ${sha256.take(8)}..."),
            deviceCheck = MeshKeySigner.blossom(MeshKeyAuth.Verb.GET, listOf(sha256), receivers, "Check blob ${sha256.take(8)}..."),
            signOwner = signOwner,
        )
    }
}

    /**
     * [deleteOverMesh] on [npub] with this device's mesh key, and once with the owner's token when the vault turns the
     * device form down without X-Mesh-Devices (or there is no mesh key here). True when the file is gone.
     */
    internal suspend fun BlossomService.deleteOnMeshDevice(npub: String, sha256: String, auth: MeshDeleteAuth): Boolean {
        var outcome = auth.device?.let { deleteOverMesh(npub, sha256, it, auth.deviceCheck) }
        if (outcome == null || (!outcome.gone && outcome.ownerRetry)) {
            val owner = auth.owner()
            if (owner == null) {
                Log.e(TAG, "Mesh delete: no mesh key and no owner's token")
            } else {
                outcome = deleteOverMesh(npub, sha256, owner, owner)
            }
        }
        return outcome?.gone == true
    }

    /**
     * BUD-02 DELETE of [sha256] on the owner's device [npub] over the mesh, through the loopback
     * ingress the reader and [com.nostrvault.fips.HomeVaultSender] use, then a HEAD to see it gone
     * ([com.nostrvault.fips.MeshDeleteTargets.gone]). Right after the engine starts the link is
     * still coming up and resets the first tries, so a dropped connection is retried for
     * [MESH_DELETE_PATIENCE_MS]. The ingress URL carries a token: logged by npub only.
     */
    internal suspend fun BlossomService.deleteOverMesh(npub: String, sha256: String, auth: String, checkAuth: String?): MeshDeleteTry {
        val deadline = System.currentTimeMillis() + MESH_DELETE_PATIENCE_MS
        while (true) {
            val base = meshIngress(npub) ?: run {
                Log.w(TAG, "Mesh delete ${npub.take(12)}: vault not reachable")
                return MeshDeleteTry(gone = false, ownerRetry = false)
            }
            try {
                val (deleteCode, ownerRetry) = remoteClient.newCall(
                    Request.Builder().url("$base/$sha256").delete()
                        .header("Authorization", "Nostr $auth").build()
                ).execute().use { it.code to MeshKeyAuth.retriesWithOwnerForm(it) }
                val checkCode = remoteClient.newCall(com.nostrvault.fips.VaultCheck.request(base, sha256, checkAuth))
                    .execute().use { it.code }
                val gone = com.nostrvault.fips.MeshDeleteTargets.gone(deleteCode, checkCode)
                if (!gone) Log.w(TAG, "Mesh delete ${npub.take(12)}: DELETE $deleteCode, then HEAD $checkCode")
                // A vault with its paired set marks its refusal final (X-Mesh-Devices): no owner token for it.
                return MeshDeleteTry(gone, ownerRetry)
            } catch (e: IOException) {
                meshForget(npub)
                if (System.currentTimeMillis() + meshRetryDelayMs > deadline) {
                    Log.w(TAG, "Mesh delete ${npub.take(12)} failed: ${e.message}")
                    return MeshDeleteTry(gone = false, ownerRetry = false)
                }
                delay(meshRetryDelayMs)
            }
        }
    }
