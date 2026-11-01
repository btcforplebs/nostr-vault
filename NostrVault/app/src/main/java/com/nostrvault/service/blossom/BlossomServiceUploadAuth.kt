package com.nostrvault.service

import com.nostrvault.data.model.PostingAccount
import android.util.Base64
import android.util.Log
import kotlinx.coroutines.*
import kotlinx.serialization.json.*
import okhttp3.*
import okhttp3.HttpUrl.Companion.toHttpUrlOrNull
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
        signAs: PostingAccount.Lock? = null,
    ): String = createAuthHeader(listOf(operation), sha256, uploadUrl, signAs)

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
        signAs: PostingAccount.Lock? = null,
    ): String {
        val expiration = (System.currentTimeMillis() / 1000) + 3600 // 1 hour (matches iOS)
        val tags = mutableListOf<List<String>>()
        operations.forEach { tags.add(listOf("t", it)) }
        // The "x" tag scopes auth to a specific blob; list/server-wide ops carry
        // no hash (matches iOS BUD-02 /list auth).
        sha256?.let { tags.add(listOf("x", it)) }
        tags.add(listOf("expiration", expiration.toString()))
        uploadUrl?.let { tags.add(listOf("u", it)) }
        return signAuthHeader(operations.joinToString("+"), sha256, tags, signAs)
    }

    /**
     * A delete token for the one server at [deleteUrl]: see [BlossomDeleteAuth]. Signed per server,
     * so a mirror holding its token cannot replay it against the home vault.
     */
    internal suspend fun BlossomService.createDeleteAuthHeader(
        sha256: String,
        deleteUrl: String,
        signAs: PostingAccount.Lock? = null,
    ): String = signAuthHeader("delete", sha256, BlossomDeleteAuth.tags(sha256, deleteUrl), signAs)

    /**
     * Sign a kind 24242 event with [tags] and encode it as an auth header, or "" on failure.
     *
     * Signed by the owner unless [signAs] is given: a note's media is signed
     * by the account the note posts as (Logen 2026-11-01), through that
     * account's own signer, and refused if another account became active
     * (the lockedTo check in signEventAsync). An owner-signed upload under another
     * account's note would tie the two accounts together at the server.
     */
    internal suspend fun BlossomService.signAuthHeader(
        label: String,
        sha256: String?,
        tags: List<List<String>>,
        signAs: PostingAccount.Lock? = null,
    ): String {
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
                    forceOwner = signAs == null,
                    lockedTo = signAs,
                )
            } catch (e: PostingAccount.AccountChangedException) {
                // Another account is active now: never sign this as it.
                Log.w(TAG, "Blossom auth not signed ($label): the posting account changed")
                return ""
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

/**
 * The tags of a Blossom delete token (kind 24242, BUD-02 / BUD-11). Port of iOS BlossomDeleteAuth.
 *
 * One token per server, naming that server ("server" = its host, "u" = the delete URL): a token
 * naming no server, sent to a public mirror, could be replayed by that mirror against the home
 * vault at its public name (Tron, PR 1403). Five minutes: long enough for a slow server, too short
 * to keep. [servers] adds more hosts the same token is for (one signature for several mesh vaults).
 */
internal object BlossomDeleteAuth {
    const val LIFETIME_SECONDS = 5 * 60L

    fun tags(
        sha256: String,
        deleteUrl: String,
        nowSeconds: Long = System.currentTimeMillis() / 1000,
        operations: List<String> = listOf("delete"),
        servers: List<String> = emptyList(),
    ): List<List<String>> {
        // OkHttp's parser, the one that sends the request: java.net.URI gives no host for a name
        // with "_" (my_mirror.example.com), which signed a token naming no server (Tron, PR 1403).
        val host = deleteUrl.trim().toHttpUrlOrNull()?.host
        val hosts = (listOfNotNull(host) + servers).map { it.lowercase().trimEnd('.') }.filter { it.isNotEmpty() }.distinct()
        return operations.map { listOf("t", it) } +
            listOf(listOf("x", sha256)) +
            listOfNotNull(deleteUrl.takeIf { it.isNotBlank() }?.let { listOf("u", it) }) +
            hosts.map { listOf("server", it) } +
            listOf(listOf("expiration", (nowSeconds + LIFETIME_SECONDS).toString()))
    }
}
