package com.nostrvault.service

import android.util.Base64
import android.util.Log
import kotlinx.coroutines.*
import kotlinx.serialization.json.*
import okhttp3.*
import com.nostrvault.service.BlossomService.Companion.AUTH_KIND
import com.nostrvault.service.BlossomService.Companion.AUTH_SIGN_ATTEMPTS
import com.nostrvault.service.BlossomService.Companion.AUTH_SIGN_RETRY_DELAY_MS
import com.nostrvault.service.BlossomService.Companion.TAG

    // ══════════════════════════════════════════════════════════════════
    // Auth header generation
    // ══════════════════════════════════════════════════════════════════

    /**
     * Create a Blossom auth header (kind 24242 signed event as base64).
     */
    internal suspend fun BlossomService.createAuthHeader(
        operation: String,
        sha256: String? = null,
        uploadUrl: String? = null,
    ): String = createAuthHeader(listOf(operation), sha256, uploadUrl)

    /**
     * Create a Blossom auth header that authorizes several operations at once by
     * carrying one "t" tag per verb (e.g. ["list", "upload"]). The relay matches
     * the request's verb against any present "t" tag, so a single signed event —
     * and therefore a single signer round-trip — can cover the whole mirror-in
     * (remote /list + local /upload). Critical for external signers (Amber/NIP-46
     * bunker) that prompt per signature.
     */
    internal suspend fun BlossomService.createAuthHeader(
        operations: List<String>,
        sha256: String? = null,
        uploadUrl: String? = null,
    ): String {
        val expiration = (System.currentTimeMillis() / 1000) + 3600 // 1 hour (matches iOS)
        val tags = mutableListOf<List<String>>()
        operations.forEach { tags.add(listOf("t", it)) }
        // The "x" tag scopes auth to a specific blob; list/server-wide ops carry
        // no hash (matches iOS BUD-02 /list auth).
        sha256?.let { tags.add(listOf("x", it)) }
        tags.add(listOf("expiration", expiration.toString()))
        uploadUrl?.let { tags.add(listOf("u", it)) }

        val label = operations.joinToString("+")
        // Use signEventAsync so external signers (Amber NIP-55, NIP-46) work.
        // The synchronous signEvent only handles a locally-stored key and returns
        // null under Amber (no on-device key) → empty auth header → servers reject
        // with "missing auth event" / 401. signEventAsync routes to the active
        // signing mode (amber/nip46/local).
        //
        // Retry a failed signature instead of failing the whole upload on the
        // first miss. Under Amber a signature is another app being launched and
        // brought to the front, so a single failure is ordinary — Amber not
        // resumed yet, slow to start, or a prompt dismissed by a stray tap. One
        // miss used to kill the post; the user would repost and it would work,
        // which is exactly the symptom iOS had before it grew the same retry
        // (BlossomService.swift makeUploadAuth, 3 attempts 1s apart).
        var event: NostrEvent? = null
        for (attempt in 1..AUTH_SIGN_ATTEMPTS) {
            event = try {
                nostrService.signEventAsync(
                    kind = AUTH_KIND,
                    content = if (sha256 != null) "Blossom $label ${sha256.take(8)}" else "Blossom $label",
                    tags = tags,
                    forceOwner = true,
                )
            } catch (e: SignerRejectedException) {
                // The user was asked and said no. Retrying would just re-prompt.
                Log.w(TAG, "Blossom auth signing declined by the user ($label)")
                return ""
            } catch (e: Exception) {
                Log.e(TAG, "Blossom auth signing failed ($label): ${e.message}")
                null
            }
            if (event != null) break
            Log.w(TAG, "Blossom auth signing returned no event ($label) — attempt $attempt/$AUTH_SIGN_ATTEMPTS")
            if (attempt < AUTH_SIGN_ATTEMPTS) delay(AUTH_SIGN_RETRY_DELAY_MS)
        }
        if (event == null) return ""

        val eventJson = buildString {
            val tagsJson = event.tags.joinToString(",") { tag ->
                "[${tag.joinToString(",") { "\"$it\"" }}]"
            }
            append("{\"id\":\"${event.id}\",")
            append("\"pubkey\":\"${event.pubkey}\",")
            append("\"created_at\":${event.createdAt},")
            append("\"kind\":${event.kind},")
            append("\"tags\":[$tagsJson],")
            append("\"content\":\"${event.content}\",")
            append("\"sig\":\"${event.sig}\"}")
        }

        return Base64.encodeToString(eventJson.toByteArray(), Base64.NO_WRAP)
    }

    /**
     * The client for this device's Blossom server: the self-signed-trusting
     * one on loopback and LAN IPs (what its hostname verifier accepts), real
     * TLS checks for an external server on a domain.
     */
    internal fun BlossomService.clientFor(url: String): OkHttpClient =
        if (isLocalhost(url) || com.nostrvault.data.remote.WebSocketClient.isLocalOrLanHost(url)) localClient
        else remoteClient

    internal fun BlossomService.isLocalhost(url: String): Boolean {
        val lower = url.lowercase()
        return lower.contains("localhost") || lower.contains("127.0.0.1") || lower.contains("0.0.0.0")
    }
