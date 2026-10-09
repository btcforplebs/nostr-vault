package com.nostrvault.fips

import android.util.Log
import okhttp3.Interceptor
import okhttp3.Response
import java.io.IOException
import java.util.concurrent.TimeUnit

/**
 * Reads a blob over the FIPS mesh when its author's vault is on it, else
 * through the URL as usual.
 *
 * The request keeps its original URL, so caches key on that and a blob read
 * once over the mesh is not stored under a loopback address that changes
 * every launch. A mesh read that fails or returns an error falls through to
 * the normal server.
 */
class FipsMeshInterceptor : Interceptor {
    override fun intercept(chain: Interceptor.Chain): Response {
        val request = chain.request()
        if (request.method != "GET") return chain.proceed(request)
        val url = request.url.toString()
        val sha = FipsMediaRouter.sha256In(url) ?: return chain.proceed(request)
        val author = FipsMediaRouter.authorOf(sha) ?: return chain.proceed(request)
        val npub = FipsMediaRouter.meshNpubFor(author) ?: return chain.proceed(request)
        val base = FipsMediaRouter.ingressBase(npub) ?: return chain.proceed(request)

        try {
            val mesh = chain
                .withConnectTimeout(5, TimeUnit.SECONDS)
                .withReadTimeout(10, TimeUnit.SECONDS)
                .proceed(request.newBuilder().url("$base/$sha").build())
            if (mesh.isSuccessful) {
                Log.i(TAG, "read ${sha.take(8)} via mesh from ${npub.take(12)}")
                return mesh.newBuilder()
                    .request(request)
                    .header(VIA_HEADER, "fips")
                    .build()
            }
            Log.w(TAG, "mesh read ${sha.take(8)}: HTTP ${mesh.code}, using the URL")
            mesh.close()
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
    }
}
