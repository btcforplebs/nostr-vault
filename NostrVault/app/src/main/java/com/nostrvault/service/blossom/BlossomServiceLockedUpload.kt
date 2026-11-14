package com.nostrvault.service

import android.util.Log
import com.nostrvault.service.BlossomService.Companion.TAG
import com.nostrvault.service.BlossomService.UploadSource

/** Takes locked files when the user's own servers refuse them (Logen 2026-11-14; primal 415, nostr.build "file type not allowed"). */
const val LOCKED_FILE_FALLBACK_SERVER = "https://nostr.download"

/**
 * Uploads a locked DM file's ciphertext ([DMFile]) exactly as it is, to an outside server only: the
 * account's public media servers at once, then [LOCKED_FILE_FALLBACK_SERVER] when none took it.
 * Never to this device's relay or the home vault (a DM attachment, and the vault serves any blob
 * to anyone with its hash). A server whose link doesn't name [x] (one that re-encoded the upload)
 * doesn't count: the other person checks the file against x and would get nothing.
 * Web: dm-file.js encryptedPhoto (up.sha256 must be x).
 */
internal suspend fun BlossomService.uploadLocked(cipher: ByteArray, x: String): String? {
    val auth = createAuthHeader("upload", x)
    if (auth.isEmpty()) {
        Log.e(TAG, "Locked upload: no Blossom auth (signer unavailable)")
        return null
    }
    val source = UploadSource.Data(cipher)
    val own = lockedUploadServers(configStore.config.value.activeBlossomMirrors)
    val jobs: List<suspend () -> String?> = own.map { server ->
        suspend { uploadToServer(source, server, x, LOCKED_FILE_TYPE, auth)?.takeIf { namesHash(it, x) } }
    }
    FirstAnswer.first(scope, jobs)?.let { return it }
    Log.w(TAG, "Locked upload: none of ${own.size} servers took ${x.take(8)}; trying $LOCKED_FILE_FALLBACK_SERVER")
    return uploadToServer(source, LOCKED_FILE_FALLBACK_SERVER, x, LOCKED_FILE_TYPE, auth)?.takeIf { namesHash(it, x) }
}

internal const val LOCKED_FILE_TYPE = "application/octet-stream"

/** The account's servers a recipient can reach: not this device, not a LAN or Tailscale address, not the fallback twice. */
internal fun lockedUploadServers(mirrors: List<String>): List<String> =
    mirrors.map { it.trimEnd('/') }
        .filter { !BlossomUploadReply.isOnDevice(it) && !com.nostrvault.relay.isPrivateNetworkURL(it) }
        .filter { it != LOCKED_FILE_FALLBACK_SERVER }
        .distinct()

/** Whether [url]'s last path segment is [x] (with or without an extension). */
internal fun namesHash(url: String, x: String): Boolean {
    val path = runCatching { java.net.URI(url).path }.getOrNull() ?: return false
    return path.substringAfterLast('/').substringBefore('.').equals(x, ignoreCase = true)
}
