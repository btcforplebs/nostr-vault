package com.nostrvault.fips

import okhttp3.Call
import okhttp3.Connection
import okhttp3.Interceptor
import okhttp3.Protocol
import okhttp3.Request
import okhttp3.Response
import okhttp3.ResponseBody.Companion.toResponseBody
import java.io.IOException
import java.lang.reflect.Proxy
import java.util.concurrent.TimeUnit

/**
 * An OkHttp chain for the mesh interceptor's tests: every request it is asked
 * to send goes to [answer], which returns a response or throws, as a server or
 * a dropped connection would. [canceled] is what the call reports.
 */
internal class MeshTestChain(
    private val request: Request,
    private val answer: (Request) -> Response,
) : Interceptor.Chain {
    val sent = mutableListOf<String>()
    var canceled = false

    private val call: Call = Proxy.newProxyInstance(Call::class.java.classLoader, arrayOf(Call::class.java)) { _, method, _ ->
        when (method.name) {
            "isCanceled" -> canceled
            "request" -> request
            else -> throw UnsupportedOperationException(method.name)
        }
    } as Call

    override fun request(): Request = request
    override fun proceed(request: Request): Response {
        sent += request.url.toString()
        return answer(request)
    }
    override fun connection(): Connection? = null
    override fun call(): Call = call
    override fun connectTimeoutMillis(): Int = 0
    override fun withConnectTimeout(timeout: Int, unit: TimeUnit): Interceptor.Chain = this
    override fun readTimeoutMillis(): Int = 0
    override fun withReadTimeout(timeout: Int, unit: TimeUnit): Interceptor.Chain = this
    override fun writeTimeoutMillis(): Int = 0
    override fun withWriteTimeout(timeout: Int, unit: TimeUnit): Interceptor.Chain = this

    companion object {
        fun reply(request: Request, code: Int, body: ByteArray = ByteArray(0)): Response = Response.Builder()
            .request(request).protocol(Protocol.HTTP_1_1).code(code).message("x").body(body.toResponseBody()).build()

        fun reset(): Nothing = throw IOException("Connection reset")
    }
}
