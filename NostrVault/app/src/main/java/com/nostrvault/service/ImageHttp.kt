package com.nostrvault.service

import okhttp3.OkHttpClient
import java.util.concurrent.TimeUnit

/**
 * The app's one HTTP connection pool for pictures and media. Each
 * `OkHttpClient.Builder()` is a pool and dispatcher of its own, so the avatar
 * loader, the feed prefetch, the media gallery and the content-type probe each
 * opened their own TLS connections to the same image hosts. Everything here
 * derives from [root] with `newBuilder()`, which shares its pool.
 */
object ImageHttp {
    /** No interceptors: for callers that only want the shared pool (HEAD probes, listings). */
    val root: OkHttpClient by lazy { OkHttpClient.Builder().build() }

    /**
     * Coil's client: the local blossom cache and the FIPS mesh first, then
     * the network. The app loader and the avatar loader both use it.
     */
    val images: OkHttpClient by lazy {
        root.newBuilder()
            .connectTimeout(15, TimeUnit.SECONDS)
            .readTimeout(15, TimeUnit.SECONDS)
            // A photo whose URL fails may wait up to 90 s for its owner's vault over the mesh (FipsMeshInterceptor).
            .callTimeout(120, TimeUnit.SECONDS)
            // Blossom media through Morganite when it runs on this phone.
            .addInterceptor(LocalBlossomCache.interceptor)
            // A friend's vault on the FIPS mesh serves its blobs directly.
            .addInterceptor(com.nostrvault.fips.FipsMeshInterceptor())
            // A .fips read the mesh did not take never goes to DNS.
            .addInterceptor(com.nostrvault.fips.FipsHostGuard)
            .build()
    }
}
