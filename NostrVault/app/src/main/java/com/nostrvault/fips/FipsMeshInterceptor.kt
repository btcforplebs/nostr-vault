package com.nostrvault.fips

import android.util.Log
import okhttp3.Interceptor
import okhttp3.Request
import okhttp3.Response
import okhttp3.ResponseBody.Companion.toResponseBody
import okio.Buffer
import okio.BufferedSource
import java.io.IOException
import java.security.MessageDigest
import java.util.concurrent.TimeUnit

/**
 * Reads a note's photo from its author's vault on the FIPS mesh when its URL
 * fails, as iOS does (#1079, #1080, #1081) and the web does (NIP-F1).
 *
 * Only requests tagged with [MeshAuthor], for an author the owner follows,
 * go to the mesh. An ordinary URL is tried first; only when it fails (no
 * connection, or not a 2xx) is the mesh asked. A `.fips` URL can only be
 * reached over the mesh, so the mesh goes first for it. Up to
 * [FipsMediaRouter.MAX_VAULTS] vaults the author lists are asked in order,
 * each for up to [READ_PATIENCE_MS] with a try every [READ_RETRY_MS]: right
 * after the engine starts the mesh has no route yet and the first connection
 * is reset. One photo gives up after [PHOTO_PATIENCE_MS].
 *
 * The whole body is read, capped at [MAX_BYTES], and hashed before any of it
 * is used: the mesh vault is trusted no more than any other server. The
 * request keeps its original URL, so caches key on that and a blob read once
 * over the mesh is not stored under a loopback address that changes every
 * launch. While the mesh is asked, [MeshMediaStatus] says so for the views.
 */
class FipsMeshInterceptor : Interceptor {
    override fun intercept(chain: Interceptor.Chain): Response {
        val request = chain.request()
        if (request.method != "GET") return chain.proceed(request)
        val author = request.tag(MeshAuthor::class.java)?.pubkey ?: return chain.proceed(request)
        val sha = FipsMediaRouter.sha256In(request.url.toString()) ?: return chain.proceed(request)

        // A `.fips` URL is only reachable over the mesh, so the mesh goes first.
        if (FipsMediaRouter.meshNpubInHost(request.url.host) != null) {
            meshRead(chain, request, author, sha)?.let { return it }
            return chain.proceed(request)
        }

        // The URL as usual first: most photos are where the note says.
        val failed: Response = try {
            val response = chain.proceed(request)
            if (response.isSuccessful) return response
            response
        } catch (e: IOException) {
            if (chain.call().isCanceled()) throw e
            meshRead(chain, request, author, sha)?.let { return it }
            throw e
        }
        val contentType = failed.body?.contentType()
        failed.close()
        meshRead(chain, request, author, sha)?.let { return it }
        // The URL's own answer, without the body that was closed to ask the mesh.
        return failed.newBuilder().body(ByteArray(0).toResponseBody(contentType)).build()
    }

    /** The photo from the author's vaults, or null (not followed, none listed, none answered with it). */
    private fun meshRead(chain: Interceptor.Chain, request: Request, author: String, sha: String): Response? {
        if (!FipsMediaRouter.mayDial(author)) return null
        MeshMediaStatus.set(sha, MeshMediaPhase.MeshLookup)
        val reply = try {
            read(chain, request, author, sha)
        } catch (e: IOException) {
            null
        }
        if (reply != null || chain.call().isCanceled()) MeshMediaStatus.clear(sha)
        else MeshMediaStatus.set(sha, MeshMediaPhase.Unreached)
        return reply
    }

    private fun read(chain: Interceptor.Chain, request: Request, author: String, sha: String): Response? {
        // A `.fips` URL may name any node; only the author's own signed list says which are theirs.
        val vaults = awaitVaults(author, request.url.host) ?: return null
        val giveUp = clock() + PHOTO_PATIENCE_MS
        for (npub in vaults) {
            val left = giveUp - clock()
            if (left <= 0) return null
            val reply = patientGet(chain, request, npub, sha, minOf(READ_PATIENCE_MS, left))
            if (reply != null) return reply
            // The photo left the screen: no further vault is asked.
            if (chain.call().isCanceled()) return null
        }
        return null
    }

    /**
     * The author's vaults. A 10063 never seen is asked for, and a read that just asked waits a few seconds for
     * it (iOS listWait), so the first photo of a newly followed author still loads by scrolling.
     */
    private fun awaitVaults(author: String, host: String): List<String>? {
        FipsMediaRouter.vaultsFor(author, host)?.let { return it }
        var waited = 0L
        while (waited < LIST_WAIT_MS) {
            sleep(LIST_POLL_MS)
            waited += LIST_POLL_MS
            if (FipsMediaRouter.hasServerList(author)) return FipsMediaRouter.vaultsFor(author, host)
        }
        return null
    }

    /**
     * The verified photo from [npub], asking again while it refuses or drops the connection: the route may
     * still be coming up. Null when this vault answered without it (the next may have it), sent wrong bytes
     * (dropped for the session) or never answered within [patience] (not dialled again for a while).
     */
    private fun patientGet(chain: Interceptor.Chain, request: Request, npub: String, sha: String, patience: Long): Response? {
        val giveUp = clock() + patience
        while (!FipsMediaRouter.isDistrusted(npub)) {
            // No mesh, or a vault that could not be dialled lately: nothing to wait for (iOS patientGet).
            val base = dial(npub) ?: return null
            try {
                return answer(chain, request, npub, base, sha)
            } catch (e: IOException) {
                // The photo left the screen: its cancelled GET says nothing about the vault.
                if (chain.call().isCanceled()) return null
                Log.w(TAG, "mesh read ${sha.take(8)} from ${npub.take(12)}: ${e.message}, asking again")
                // The node may have restarted with a new loopback base: dial again.
                FipsMediaRouter.forget(npub)
            }
            if (clock() >= giveUp) {
                Log.w(TAG, "mesh read ${sha.take(8)}: ${npub.take(12)} did not answer, next vault")
                FipsMediaRouter.markUnreachable(npub)
                return null
            }
            sleep(READ_RETRY_MS)
        }
        return null
    }

    /** One GET of the blob from [base]: the verified response, or null when this vault answered without it. */
    private fun answer(chain: Interceptor.Chain, request: Request, npub: String, base: String, sha: String): Response? {
        // A Range answer could never match the blob's hash: ask for all of it.
        val meshRequest = request.newBuilder()
            .url("$base/$sha")
            .removeHeader("Range")
            .removeHeader("If-Range")
            .build()
        chain
            .withConnectTimeout(5, TimeUnit.SECONDS)
            .withReadTimeout(10, TimeUnit.SECONDS)
            .proceed(meshRequest)
            .use { mesh ->
                val body = mesh.body
                when {
                    // Honestly missing: the vault keeps its standing, and the next one may have it.
                    mesh.code != 200 || body == null ->
                        Log.w(TAG, "mesh read ${sha.take(8)}: HTTP ${mesh.code} from ${npub.take(12)}")
                    // Honestly too big (a video, say): nothing read, the vault keeps its standing.
                    body.contentLength() > MAX_BYTES ->
                        Log.w(TAG, "mesh read ${sha.take(8)}: ${body.contentLength()} bytes is over the cap")
                    else -> {
                        val bytes = readVerified(body.source(), sha)
                        if (bytes == null) {
                            // Wrong hash, or more bytes than it announced: not a passing fault.
                            Log.w(TAG, "mesh read ${sha.take(8)}: wrong bytes or too big, dropping ${npub.take(12)}")
                            FipsMediaRouter.distrust(npub)
                        } else {
                            Log.i(TAG, "read ${sha.take(8)} via mesh from ${npub.take(12)}")
                            return mesh.newBuilder()
                                .request(request)
                                .removeHeader("Content-Length")
                                .header(VIA_HEADER, "fips")
                                .body(bytes.toResponseBody(body.contentType()))
                                .build()
                        }
                    }
                }
            }
        return null
    }

    companion object {
        private const val TAG = "FipsMesh"
        /** Set on a response that came over the mesh. */
        const val VIA_HEADER = "X-NV-Via"

        /** Opens [npub]'s vault: its loopback base, or null. A seam so a test can see which node a read would dial. */
        @Volatile
        internal var dial: (String) -> String? = { FipsMediaRouter.ingressBase(it) }

        /** Seams so a test runs the patience loop without waiting it out. */
        @Volatile
        internal var clock: () -> Long = { System.currentTimeMillis() }

        @Volatile
        internal var sleep: (Long) -> Unit = { Thread.sleep(it) }

        /** The most a mesh read will buffer. Bigger blobs come from the URL. */
        const val MAX_BYTES = 32L * 1024 * 1024

        /** How long one vault may refuse or drop the read before it counts as unreachable (iOS readPatience). */
        const val READ_PATIENCE_MS = 45_000L

        /** The pause between those tries (iOS readRetry, web blob-get RETRY_MS). */
        const val READ_RETRY_MS = 1_000L

        /** One photo across all its vaults; no new vault is tried past it (iOS photoPatience). */
        const val PHOTO_PATIENCE_MS = 90_000L

        /** How long a read waits for a 10063 it has just asked for (iOS listWait / listPoll). */
        const val LIST_WAIT_MS = 6_000L
        const val LIST_POLL_MS = 500L

        /**
         * Read all of [source], giving up past [maxBytes], and return it only
         * if its sha256 is [sha].
         */
        internal fun readVerified(source: BufferedSource, sha: String, maxBytes: Long = MAX_BYTES): ByteArray? {
            val digest = MessageDigest.getInstance("SHA-256")
            val out = Buffer()
            val chunk = ByteArray(64 * 1024)
            while (true) {
                val n = source.read(chunk)
                if (n == -1) break
                if (out.size + n > maxBytes) return null
                digest.update(chunk, 0, n)
                out.write(chunk, 0, n)
            }
            val hex = digest.digest().joinToString("") { "%02x".format(it) }
            return if (hex == sha) out.readByteArray() else null
        }
    }
}
