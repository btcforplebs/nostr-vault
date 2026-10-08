package com.nostrvault.data.remote

import android.util.Log
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import okhttp3.OkHttpClient
import okhttp3.internal.tls.OkHostnameVerifier
import java.io.File
import java.net.Socket
import java.security.KeyStore
import java.security.MessageDigest
import java.security.cert.CertificateException
import java.security.cert.X509Certificate
import javax.net.ssl.SSLContext
import javax.net.ssl.SSLEngine
import javax.net.ssl.SSLSocket
import javax.net.ssl.TrustManagerFactory
import javax.net.ssl.X509ExtendedTrustManager
import javax.net.ssl.X509TrustManager

/**
 * TLS for hosts a public certificate can't cover: this device's own relay and
 * relays on the local network, which use self-signed certificates. Port of
 * iOS LocalTLSTrust.
 *
 * Loopback is trusted as is. A LAN host's certificate is pinned the first time
 * it is seen and must match after that, so another device on the same Wi-Fi
 * can't stand in for it. Everything else gets the system's normal check. A
 * relay that comes back with a new certificate (its host was reset) is refused
 * and listed in [refused] until [forget] trusts the next one.
 */
object LocalTls {
    private const val TAG = "LocalTls"

    enum class Kind { LOOPBACK, LAN, PUBLIC }

    fun kind(host: String?): Kind {
        var h = host?.lowercase()?.takeIf { it.isNotEmpty() } ?: return Kind.PUBLIC
        if (h.startsWith("[") && h.endsWith("]")) h = h.substring(1, h.length - 1)
        if (h in setOf("localhost", "127.0.0.1", "0.0.0.0", "::1")) return Kind.LOOPBACK
        if (h.endsWith(".local")) return Kind.LAN
        val parts = h.split(".")
        if (parts.size != 4) return Kind.PUBLIC
        val octets = parts.map { p -> p.toIntOrNull()?.takeIf { p.isNotEmpty() && p.all(Char::isDigit) && it in 0..255 } ?: return Kind.PUBLIC }
        return when {
            octets[0] == 127 -> Kind.LOOPBACK
            octets[0] == 10 -> Kind.LAN
            octets[0] == 172 && octets[1] in 16..31 -> Kind.LAN
            octets[0] == 192 && octets[1] == 168 -> Kind.LAN
            else -> Kind.PUBLIC
        }
    }

    enum class Decision { ACCEPT_AND_PIN, ACCEPT, REJECT }

    /** First sight pins the certificate; after that only the same one passes. */
    fun decide(pinned: String?, presented: String): Decision = when (pinned) {
        null -> Decision.ACCEPT_AND_PIN
        presented -> Decision.ACCEPT
        else -> Decision.REJECT
    }

    // ── Pins ─────────────────────────────────────────────────────────

    /** Set by ConfigStore at startup; null (tests) keeps pins in memory only. */
    @Volatile var pinFile: File? = null

    private val lock = Any()
    private var pins: MutableMap<String, String>? = null
    private val _refused = MutableStateFlow<List<String>>(emptyList())

    /** host:port of relays refused for a changed certificate. */
    val refused: StateFlow<List<String>> = _refused.asStateFlow()

    private fun loadedPins(): MutableMap<String, String> {
        pins?.let { return it }
        val loaded = runCatching {
            pinFile?.takeIf { it.exists() }?.readText()?.let { text ->
                Json.parseToJsonElement(text).jsonObject.mapValues { it.value.jsonPrimitive.content }
            }
        }.getOrNull().orEmpty().toMutableMap()
        pins = loaded
        return loaded
    }

    private fun savePins(map: Map<String, String>) {
        runCatching { pinFile?.writeText(JsonObject(map.mapValues { JsonPrimitive(it.value) }).toString()) }
    }

    /** Forgets the saved certificate for [hostPort]; the next one is trusted. */
    fun forget(hostPort: String) = synchronized(lock) {
        val map = loadedPins()
        map.remove(hostPort)
        savePins(map)
        _refused.value = _refused.value - hostPort
    }

    /** Forgets every saved certificate (Reset App). */
    fun forgetAll() = synchronized(lock) {
        pins = mutableMapOf()
        runCatching { pinFile?.delete() }
        _refused.value = emptyList()
    }

    /** Applies [decide] for [hostPort] and records the outcome. */
    internal fun check(hostPort: String, fingerprint: String): Boolean = synchronized(lock) {
        val map = loadedPins()
        when (decide(map[hostPort], fingerprint)) {
            Decision.ACCEPT_AND_PIN -> { map[hostPort] = fingerprint; savePins(map); true }
            Decision.ACCEPT -> true
            Decision.REJECT -> {
                if (hostPort !in _refused.value) {
                    _refused.value = _refused.value + hostPort
                    Log.w(TAG, "Refused $hostPort: its certificate is not the one this app saved. " +
                        "If that relay was reset or reinstalled, trust the new one in Settings › Relays › Fixes.")
                }
                false
            }
        }
    }

    // ── OkHttp ───────────────────────────────────────────────────────

    private val systemTrust: X509TrustManager by lazy {
        val factory = TrustManagerFactory.getInstance(TrustManagerFactory.getDefaultAlgorithm())
        factory.init(null as KeyStore?)
        factory.trustManagers.filterIsInstance<X509TrustManager>().first()
    }

    private fun fingerprint(cert: X509Certificate): String =
        MessageDigest.getInstance("SHA-256").digest(cert.encoded).joinToString("") { "%02x".format(it) }

    private fun checkServer(chain: Array<X509Certificate>, authType: String, host: String?, port: Int) {
        when (kind(host)) {
            Kind.LOOPBACK -> Unit
            Kind.LAN -> {
                val leaf = chain.firstOrNull() ?: throw CertificateException("no certificate")
                if (!check("${host!!.lowercase()}:$port", fingerprint(leaf))) {
                    throw CertificateException("$host:$port presented a different certificate than the one saved")
                }
            }
            Kind.PUBLIC -> systemTrust.checkServerTrusted(chain, authType)
        }
    }

    /** Trust manager that knows the peer host (OkHttp calls the Socket overload). */
    val trustManager: X509ExtendedTrustManager = object : X509ExtendedTrustManager() {
        override fun checkServerTrusted(chain: Array<X509Certificate>, authType: String, socket: Socket?) {
            val session = (socket as? SSLSocket)?.handshakeSession
            checkServer(chain, authType, session?.peerHost, session?.peerPort ?: -1)
        }
        override fun checkServerTrusted(chain: Array<X509Certificate>, authType: String, engine: SSLEngine?) =
            checkServer(chain, authType, engine?.peerHost, engine?.peerPort ?: -1)
        override fun checkServerTrusted(chain: Array<X509Certificate>, authType: String) =
            systemTrust.checkServerTrusted(chain, authType)
        override fun checkClientTrusted(chain: Array<X509Certificate>, authType: String, socket: Socket?) =
            throw CertificateException("client certificates are not accepted")
        override fun checkClientTrusted(chain: Array<X509Certificate>, authType: String, engine: SSLEngine?) =
            throw CertificateException("client certificates are not accepted")
        override fun checkClientTrusted(chain: Array<X509Certificate>, authType: String) =
            throw CertificateException("client certificates are not accepted")
        override fun getAcceptedIssuers(): Array<X509Certificate> = systemTrust.acceptedIssuers
    }

    /** Uses [trustManager]; local and LAN names skip the hostname check, which the pin replaces. */
    fun OkHttpClient.Builder.localTrust(): OkHttpClient.Builder {
        val context = SSLContext.getInstance("TLS")
        context.init(null, arrayOf(trustManager), null)
        sslSocketFactory(context.socketFactory, trustManager)
        hostnameVerifier { hostname, session ->
            kind(hostname) != Kind.PUBLIC || OkHostnameVerifier.verify(hostname, session)
        }
        return this
    }
}
