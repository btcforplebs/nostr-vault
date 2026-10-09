package com.nostrvault.fips

import android.util.Log
import okhttp3.Interceptor
import okhttp3.Response
import okhttp3.ResponseBody.Companion.toResponseBody
import okio.Buffer
import okio.BufferedSource
import java.io.IOException
import java.security.MessageDigest
import java.util.concurrent.TimeUnit

/**
 * Reads a blob over the FIPS mesh when the note's author has a vault on it,
 * else through the URL as usual (NIP-F1).
 *
 * Only requests tagged with [MeshAuthor], for an author the owner follows,
 * go to the mesh. The whole body is
 * read, capped at [MAX_BYTES], and hashed before any of it is used: the mesh
 * vault is trusted no more than any other server. The request keeps its
 * original URL, so caches key on that and a blob read once over the mesh is
 * not stored under a loopback address that changes every launch. Anything
 * short of a 200 whose bytes match the hash falls through to the URL.
 */
class FipsMeshInterceptor : Interceptor {
    override fun intercept(chain: Interceptor.Chain): Response {
        val request = chain.request()
        if (request.method != "GET") return chain.proceed(request)
        val author = request.tag(MeshAuthor::class.java)?.pubkey ?: return chain.proceed(request)
        if (!FipsMediaRouter.mayDial(author)) return chain.proceed(request)
        val sha = FipsMediaRouter.sha256In(request.url.toString()) ?: return chain.proceed(request)
        val npub = FipsMediaRouter.meshNpubFor(author) ?: return chain.proceed(request)
        val base = FipsMediaRouter.ingressBase(npub) ?: return chain.proceed(request)

        try {
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
                        mesh.code != 200 || body == null ->
                            Log.w(TAG, "mesh read ${sha.take(8)}: HTTP ${mesh.code}, using the URL")
                        // Honestly too big (a video, say): nothing read, the vault keeps its standing.
                        body.contentLength() > MAX_BYTES ->
                            Log.w(TAG, "mesh read ${sha.take(8)}: ${body.contentLength()} bytes is over the cap, using the URL")
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
        } catch (e: IOException) {
            Log.w(TAG, "mesh read ${sha.take(8)} failed, using the URL: ${e.message}")
            FipsMediaRouter.forget(npub)
        }
        return chain.proceed(request)
    }

    companion object {
        private const val TAG = "FipsMesh"
        /** Set on a response that came over the mesh. */
        const val VIA_HEADER = "X-NV-Via"

        /** The most a mesh read will buffer. Bigger blobs come from the URL. */
        const val MAX_BYTES = 32L * 1024 * 1024

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
