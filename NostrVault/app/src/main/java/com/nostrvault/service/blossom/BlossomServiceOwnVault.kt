package com.nostrvault.service

import android.util.Log
import com.nostrvault.relay.HavenBridge
import com.nostrvault.service.BlossomService.Companion.TAG
import java.io.File

/**
 * How Import media puts a file into this device's own vault. A vault with an
 * account key (or a signer) uploads over HTTP with a signed kind 24242, as it
 * always did. A keyless vault (npub only) can't sign that, so it used to
 * import nothing (0/250 server blobs, 0/71 note media on a 12 mini): it hands
 * the file to the vault in-process instead ([HavenBridge.importOwnerBlob]),
 * which is no HTTP route, so nobody else gains a way to upload. The signer is
 * never asked on that path.
 */
sealed interface OwnVaultAuth {
    /** No key here: the in-process path, no signature. */
    data object Keyless : OwnVaultAuth

    /** The signed upload header (base64 kind 24242), reused for every file. */
    data class Signed(val header: String) : OwnVaultAuth

    companion object {
        /**
         * The way in for this run, or null when a keyed vault's signer gave
         * nothing (the run stops, as before). [sign] is only called for a
         * keyed vault.
         */
        suspend fun of(keyless: Boolean, sign: suspend () -> String): OwnVaultAuth? =
            if (keyless) Keyless else sign().takeIf { it.isNotEmpty() }?.let(::Signed)
    }
}

internal object OwnVaultFile {
    /**
     * Writes [data] to a temp file in [dir] and hands its path to [store]
     * (path, sha256, type). The temp file is deleted whatever happens.
     */
    fun store(data: ByteArray, sha256: String, contentType: String, dir: File? = null, store: (String, String, String) -> Boolean): Boolean {
        val temp = File.createTempFile("import-${sha256.take(16)}-", ".blob", dir)
        return try {
            temp.writeBytes(data)
            store(temp.absolutePath, sha256, contentType)
        } finally {
            temp.delete()
        }
    }
}

/** This run's way into the vault: keyless asks no signer; keyed signs one header for [verbs]. */
internal suspend fun BlossomService.ownVaultAuth(verbs: List<String>): OwnVaultAuth? =
    OwnVaultAuth.of(nostrService.isReadOnlyAccount()) { createAuthHeader(verbs) }

/** Saves one downloaded file into this device's vault the way [auth] says. */
internal suspend fun BlossomService.saveToOwnVault(data: ByteArray, sha256: String, contentType: String, auth: OwnVaultAuth): Boolean =
    when (auth) {
        is OwnVaultAuth.Signed -> saveToLocalRelay(data, sha256, contentType, auth.header)
        OwnVaultAuth.Keyless -> try {
            OwnVaultFile.store(data, sha256, contentType) { path, sha, type -> HavenBridge.importOwnerBlob(path, sha, type) }
        } catch (e: Exception) {
            Log.w(TAG, "Keyless vault import of ${sha256.take(8)} failed: ${e.message}")
            false
        }
    }
