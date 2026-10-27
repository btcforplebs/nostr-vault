package com.nostrvault.service

import android.util.Log
import kotlinx.coroutines.*
import kotlinx.serialization.json.*
import okhttp3.*
import com.nostrvault.service.BlossomService.Companion.TAG
import com.nostrvault.service.BlossomService.PostUploadOutcome
import com.nostrvault.service.BlossomService.UploadAttempt
import com.nostrvault.service.BlossomService.UploadSource

    internal suspend fun BlossomService.upload(
        source: UploadSource,
        sha256: String,
        contentType: String,
        skipOutsideServers: Boolean,
        /** False for DM attachments: the vault's mesh door serves any blob to anyone with its hash. */
        toHomeVault: Boolean = true,
    ): UploadAttempt = withContext(Dispatchers.IO) {
        // Sign the BUD-02 auth event ONCE and reuse it for the local relay and
        // every mirror. The event is server-agnostic (no "u" tag), so one
        // signature is valid everywhere. This is required for external signers:
        // Amber serializes signing through a single activity and fails on the
        // concurrent requests that per-destination signing would produce.
        val authHeader = createAuthHeader("upload", sha256)
        if (authHeader.isEmpty()) {
            Log.e(TAG, "Upload aborted: could not create Blossom auth event (signer unavailable)")
            return@withContext UploadAttempt(PostUploadOutcome.NotSavedOnDevice, null)
        }

        val localUrl = localBlossomURL()
        val localOk = when {
            localUrl == null -> false
            source is UploadSource.Data -> saveToLocalRelay(source.data, sha256, contentType, authHeader)
            else -> saveToLocalRelay((source as UploadSource.FileSource).file, sha256, contentType, authHeader)
        }
        if (!localOk) Log.w(TAG, "Local relay upload failed for ${sha256.take(8)} — continuing with mirrors")
        // The owner's home vault on the mesh gets a copy too; it queues while unreachable.
        if (toHomeVault) when (source) {
            is UploadSource.Data -> homeVault.offerBlob(sha256, contentType, source.data)
            is UploadSource.FileSource -> homeVault.offerBlob(sha256, contentType, source.file)
        }
        val savedLocalUrl = if (localOk && localUrl != null) "$localUrl/$sha256" else null

        fun notHosted(mirrors: List<String>): PostUploadOutcome = notHostedOutcome(localOk, mirrors)

        val mirrors = configStore.config.value.activeBlossomMirrors

        // An external Blossom server on a public address (Nostr Vault for Mac
        // on a domain) already hosts it: its URL is the one the post carries.
        // Mirrors still get a copy, but one pass and no wait. A LAN or
        // Tailscale address only opens for the owner, so it takes the normal
        // path below, like the built-in relay.
        if (savedLocalUrl != null && !com.nostrvault.relay.isPrivateNetworkURL(savedLocalUrl)) {
            if (mirrors.isNotEmpty() && !skipOutsideServers) {
                scope.launch { mirrorUploadPass(source, mirrors, sha256, contentType, authHeader) }
            }
            return@withContext UploadAttempt(PostUploadOutcome.Hosted(savedLocalUrl), savedLocalUrl)
        }

        if (mirrors.isEmpty()) {
            Log.e(TAG, "No Blossom mirrors configured — refusing to embed a localhost media URL")
            return@withContext UploadAttempt(notHosted(mirrors), savedLocalUrl)
        }

        // Only skip when the blob is safe here; if the local save failed, an
        // outside server is the only place it can go, so try them anyway.
        if (skipOutsideServers && localOk) {
            if (toHomeVault) hostedViaHomeVault(sha256, contentType, mirrors)?.let { return@withContext UploadAttempt(it, savedLocalUrl) }
            Log.i(TAG, "Saved ${sha256.take(8)} on this device only — an earlier attachment found every outside server down")
            return@withContext UploadAttempt(PostUploadOutcome.SavedOnDevice(mirrors), savedLocalUrl)
        }

        var external = mirrorUploadPass(source, mirrors, sha256, contentType, authHeader)

        // A sleeping mirror host (e.g. the Mac relay over LAN/Tailscale) is often
        // woken *by* the first pass's connection attempts (wake-on-network) but
        // isn't up fast enough to serve it. Wait and retry the whole pass once
        // before handing the post to the queue.
        if (external == null) {
            Log.w(TAG, "All Blossom mirrors failed — retrying once in 10s in case a sleeping host is still waking")
            delay(10_000)
            external = mirrorUploadPass(source, mirrors, sha256, contentType, authHeader)
        }

        if (external == null) {
            Log.e(TAG, "All Blossom mirror uploads failed for ${sha256.take(8)} (saved on this device: $localOk)")
            // The public copy is pushed from this phone's relay, so only when it is here.
            if (localOk && toHomeVault) {
                hostedViaHomeVault(sha256, contentType, mirrors)?.let { return@withContext UploadAttempt(it, savedLocalUrl) }
            }
            return@withContext UploadAttempt(notHosted(mirrors), savedLocalUrl)
        }
        UploadAttempt(PostUploadOutcome.Hosted(external), savedLocalUrl)
    }

/**
 * What to report when no outside server hosted a blob. A post may only wait for a server if the blob is actually on
 * this device. With no media server at all it is [BlossomService.PostUploadOutcome.NoOutsideServer], the "set up a
 * media server" path, as on iPhone: never a post that waits on the home vault alone, since a mesh-only note is one
 * no other app can load (NIP-F1).
 */
internal fun notHostedOutcome(localOk: Boolean, mirrors: List<String>): BlossomService.PostUploadOutcome = when {
    !localOk -> BlossomService.PostUploadOutcome.NotSavedOnDevice
    mirrors.isEmpty() -> BlossomService.PostUploadOutcome.NoOutsideServer
    else -> BlossomService.PostUploadOutcome.SavedOnDevice(mirrors)
}
