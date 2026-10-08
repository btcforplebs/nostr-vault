package com.nostrvault.data.remote

import com.nostrvault.data.remote.LocalTls.localTrust
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.mockwebserver.MockResponse
import okhttp3.mockwebserver.MockWebServer
import okhttp3.tls.HandshakeCertificates
import okhttp3.tls.HeldCertificate
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Assume.assumeTrue
import org.junit.Test
import java.net.InetAddress
import java.net.NetworkInterface
import javax.net.ssl.SSLHandshakeException

/**
 * Real TLS handshakes against a self-signed server on this machine's LAN
 * address, through the client [LocalTls.localTrust] builds. Proves the trust
 * manager sees the peer host (so the pin applies) and that a changed
 * certificate is refused until forgotten. Skipped without a private IPv4.
 */
class LocalTlsHandshakeTest {
    private val servers = mutableListOf<MockWebServer>()

    @After
    fun tearDown() {
        servers.forEach { it.shutdown() }
        LocalTls.forgetAll()
    }

    private fun lanAddress(): InetAddress? = NetworkInterface.getNetworkInterfaces().toList()
        .flatMap { it.inetAddresses.toList() }
        .firstOrNull { it.hostAddress?.let { a -> LocalTls.kind(a) == LocalTls.Kind.LAN } == true }

    private fun serve(address: InetAddress, port: Int): MockWebServer {
        val cert = HeldCertificate.Builder().addSubjectAlternativeName(address.hostAddress!!).build()
        val server = MockWebServer()
        server.useHttps(HandshakeCertificates.Builder().heldCertificate(cert).build().sslSocketFactory(), false)
        server.enqueue(MockResponse().setBody("ok"))
        server.start(address, port)
        servers += server
        return server
    }

    private val client = OkHttpClient.Builder().localTrust().build()

    private fun get(server: MockWebServer): String =
        client.newCall(Request.Builder().url(server.url("/")).build()).execute().use { it.body!!.string() }

    @Test
    fun `a LAN relay is pinned, a new certificate is refused, and Trust New takes it`() {
        val address = lanAddress()
        assumeTrue("no private IPv4 on this machine", address != null)
        val first = serve(address!!, 0)
        val port = first.port
        assertEquals("ok", get(first))

        first.shutdown(); servers.remove(first)
        val second = serve(address, port)
        val refused = runCatching { get(second) }.exceptionOrNull()
        assertTrue("expected a TLS refusal, got $refused", refused is SSLHandshakeException)
        assertEquals(listOf("${address.hostAddress}:$port"), LocalTls.refused.value)

        LocalTls.forget("${address.hostAddress}:$port")
        second.enqueue(MockResponse().setBody("ok"))
        assertEquals("ok", get(second))
    }
}
