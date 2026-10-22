package com.nostrvault.fips

import okhttp3.Interceptor
import okhttp3.Response
import java.io.IOException

/**
 * Refuses any request still aimed at a `.fips` host, so a mesh name never
 * reaches DNS (matches iOS FipsHostBlocker, #992).
 *
 * A `.fips` host is only reachable through [FipsMeshInterceptor], which
 * rewrites the read to the vault's loopback base. Add this after it: what
 * arrives here with a `.fips` host is a read the mesh did not take, and
 * resolving the name would leak the npub to the resolver.
 */
object FipsHostGuard : Interceptor {
    class Refused(host: String) : IOException("$host is a FIPS mesh name; not sent to DNS")

    fun isFipsHost(host: String): Boolean =
        host.trimEnd('.').lowercase().let { it == "fips" || it.endsWith(".fips") }

    override fun intercept(chain: Interceptor.Chain): Response {
        val host = chain.request().url.host
        if (isFipsHost(host)) throw Refused(host)
        return chain.proceed(chain.request())
    }
}
