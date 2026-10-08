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
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.net.InetAddress
import java.net.NetworkInterface
import javax.net.ssl.SSLHandshakeException

/**
 * Real TLS handshakes against a self-signed server on this machine's LAN
 * address, through the client [LocalTls.localTrust] builds. Proves the trust
 * manager sees the peer host (so the pin applies) and that a changed
 * certificate is refused until forgotten. Fails, rather than passing having
 * proved nothing, on a machine with no private IPv4 address.
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

    private fun get(server: MockWebServer, host: String? = null, http: OkHttpClient = client): String {
        val url = server.url("/").let { if (host == null) it else it.newBuilder().host(host).build() }
        return http.newCall(Request.Builder().url(url).build()).execute().use { it.body!!.string() }
    }

    private fun requireLan(): InetAddress {
        val address = lanAddress()
        assertNotNull("this test needs a private IPv4 address (10/8, 172.16/12 or 192.168/16) on the machine", address)
        return address!!
    }

    @Test
    fun `a LAN relay is pinned, a new certificate is refused, and Trust New takes it`() {
        val address = requireLan()
        val first = serve(address, 0)
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

    /**
     * A .local relay is pinned under its name, not the address it resolved
     * to, so a new DHCP lease doesn't count as a new relay (and re-pin).
     */
    @Test
    fun `a dot-local relay is pinned by name`() {
        val address = requireLan()
        val name = "nostrvault-test.local"
        val http = OkHttpClient.Builder().localTrust()
            .dns(object : okhttp3.Dns {
                override fun lookup(hostname: String) =
                    if (hostname == name) listOf(address) else okhttp3.Dns.SYSTEM.lookup(hostname)
            })
            .build()
        val first = serve(address, 0)
        val port = first.port
        assertEquals("ok", get(first, name, http))

        first.shutdown(); servers.remove(first)
        val second = serve(address, port)
        assertTrue(runCatching { get(second, name, http) }.exceptionOrNull() is SSLHandshakeException)
        assertEquals(listOf("$name:$port"), LocalTls.refused.value)
    }
}

