package com.nostrvault.ui.screens.settings

import java.io.EOFException
import java.net.ConnectException
import java.net.NoRouteToHostException
import java.net.SocketTimeoutException
import java.net.UnknownHostException
import java.security.cert.CertificateException
import javax.net.ssl.SSLException

/**
 * Why a relay didn't connect, in a few plain words for the Relays page (Logen 2026-11-04, from the NDK check: show
 * the real reason, not just "not answering"). Twin of iOS `RelayFailReason.swift`.
 */
object RelayFailReason {
    /** The probe's own wait ran out. */
    fun noAnswer(seconds: Int) = "no answer in $seconds s"

    /** [httpStatus]: what the server answered the WebSocket upgrade with, if it answered at all. */
    fun text(httpStatus: Int?, error: Throwable?): String {
        if (httpStatus != null && httpStatus != 101 && httpStatus > 0) {
            return when (httpStatus) {
                401, 403 -> "refused (HTTP $httpStatus)"
                404 -> "no relay at this address (HTTP 404)"
                429 -> "rate-limited (HTTP 429)"
                in 200..299 -> "not a relay (answered with a web page)"
                in 500..599 -> "server error (HTTP $httpStatus)"
                else -> "HTTP $httpStatus"
            }
        }
        // The cause chain: OkHttp wraps some of these.
        var e = error
        while (e != null) {
            when (e) {
                is UnknownHostException -> return "no such host"
                is ConnectException -> return "connection refused"
                is NoRouteToHostException -> return "no route to the host"
                is SocketTimeoutException -> return "timed out"
                is SSLException, is CertificateException -> return "certificate problem"
                is EOFException -> return "connection dropped"
            }
            e = e.cause?.takeIf { it !== e }
        }
        return "not answering"
    }
}

/** A probe socket's failure with the HTTP answer to its upgrade, if there was one. */
class RelayProbeFailure(val httpStatus: Int?, cause: Throwable) : Exception(cause)
