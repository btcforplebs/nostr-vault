package com.nostrvault.fips

import android.content.Context
import android.util.Log
import dagger.hilt.android.qualifiers.ApplicationContext
import java.io.InputStream
import java.io.OutputStream
import java.net.InetAddress
import java.net.InetSocketAddress
import java.net.ServerSocket
import java.net.Socket
import java.net.URI
import javax.inject.Inject
import javax.inject.Singleton
import kotlin.concurrent.thread

/**
 * The other vault's lasting address, for "Copy from my other vault" on the new phone (B).
 *
 * [FipsBridge.ingress] hands out a fresh loopback port on every dial, and that port dies with the engine. A link
 * restarts the engine (My Devices changed), and so does an app restart, so a cut setup or `older_relays` read the
 * seed it was given, a dead port, and the copy never resumed. The relay keys what it still has to read by that URL.
 *
 * So the relay is given this instead: a loopback port kept on disk with the other vault's mesh npub, reopened on
 * every engine start while [OtherVaultCopy.KEEP_LINK_MS] lasts, that forwards each connection to the current
 * ingress for the npub (dialed again when the old one is gone). Loopback only, like the ingress.
 *
 * Any app on this phone can reach a loopback port, and behind this one is the other vault's relay port, which
 * treats an own device like its own app (notes, the Blossom list and blobs, no AUTH). So the address carries a
 * per-link secret, `ws://127.0.0.1:<port>/<token>`: a connection whose first request line doesn't start with it is
 * closed before anything is dialed, and the token is taken out of the path before the bytes go on (Tron, #1777).
 * Neither the address nor the token is ever logged.
 */
@Singleton
class OtherVaultLink internal constructor(
    private val store: Store,
    private val dial: (String) -> String?,
) {
    @Inject constructor(@ApplicationContext context: Context) :
        this(PrefsStore(context), { npub -> FipsBridge.ingress(npub).url })

    /** Where the kept address lives between runs. */
    interface Store {
        var npub: String?
        var port: Int
        var until: Long
        var token: String?
    }

    private var server: ServerSocket? = null

    /** The current ingress for the npub (`host:port`), cached so a dial per connection doesn't open a port each. */
    @Volatile private var target: InetSocketAddress? = null

    /** B, once linked: the lasting ws:// address for [npub], kept until [OtherVaultCopy.KEEP_LINK_MS] from [now]. */
    @Synchronized
    fun open(npub: String, now: Long = System.currentTimeMillis()): String? {
        if (store.npub != npub || store.token == null) {
            closeServer()
            store.port = 0
            store.token = newToken()
        }
        store.npub = npub
        store.until = now + OtherVaultCopy.KEEP_LINK_MS
        target = null
        return listen(npub)
    }

    /** On an engine start: the kept address comes back on the same port; an expired one is let go. */
    @Synchronized
    fun restore(now: Long = System.currentTimeMillis()) {
        val npub = store.npub ?: return
        // No token: an address from before the secret (Tron, #1777) is let go, never reopened open to any app.
        if (!OtherVaultCopy.open(store.until, now) || store.token == null) return close()
        target = null  // the engine restarted: the old ingress is gone
        listen(npub)
    }

    /** Copied: nothing is left to read from the other vault. */
    @Synchronized
    fun close() {
        closeServer()
        store.npub = null
        store.port = 0
        store.until = 0
        store.token = null
    }

    /** The address in use, or null. */
    @Synchronized
    fun url(): String? = server?.takeIf { !it.isClosed }?.let { s -> store.token?.let { address(s.localPort, it) } }

    private fun listen(npub: String): String? {
        url()?.let { return it }
        val token = store.token ?: return null
        // The same port as before when it is free, so the relay's saved URL still answers.
        val s = bind(store.port) ?: bind(0) ?: return null
        store.port = s.localPort
        server = s
        thread(name = "other-vault-link", isDaemon = true) { accept(s, npub, token) }
        return address(s.localPort, token)
    }

    private fun bind(port: Int): ServerSocket? = try {
        ServerSocket().apply {
            reuseAddress = true
            bind(InetSocketAddress(InetAddress.getLoopbackAddress(), port))
        }
    } catch (e: Exception) {
        null
    }

    private fun closeServer() {
        runCatching { server?.close() }
        server = null
    }

    private fun accept(s: ServerSocket, npub: String, token: String) {
        while (!s.isClosed) {
            val client = try { s.accept() } catch (e: Exception) { break }
            thread(name = "other-vault-link-conn", isDaemon = true) { forward(client, npub, token) }
        }
    }

    private fun forward(client: Socket, npub: String, token: String) {
        // The first request line, checked before anything is dialed: no token, no connection.
        val line = runCatching {
            client.soTimeout = REQUEST_LINE_TIMEOUT_MS
            readLine(client.getInputStream()).also { client.soTimeout = 0 }
        }.getOrNull()
        val rewritten = line?.let { withoutToken(it, token) }
        val upstream = rewritten?.let { connect(npub) }
        if (rewritten == null || upstream == null) {
            runCatching { client.close() }
            return
        }
        try {
            upstream.getOutputStream().write(rewritten.toByteArray(Charsets.ISO_8859_1))
        } catch (e: Exception) {
            runCatching { client.close() }
            runCatching { upstream.close() }
            return
        }
        thread(name = "other-vault-link-up", isDaemon = true) { pipe(client.getInputStream(), upstream.getOutputStream(), upstream, client) }
        pipe(upstream.getInputStream(), client.getOutputStream(), client, upstream)
    }

    /** The cached ingress, else a fresh dial; once more on a refused connect (the engine restarted). */
    internal fun connect(npub: String): Socket? {
        repeat(2) {
            val t = target ?: resolve(npub)?.also { target = it } ?: return null
            try {
                return Socket().apply { connect(t, CONNECT_TIMEOUT_MS) }
            } catch (e: Exception) {
                target = null
            }
        }
        Log.w(TAG, "other vault not reached")  // never the address: the ingress is a capability
        return null
    }

    private fun resolve(npub: String): InetSocketAddress? {
        val uri = dial(npub)?.let { runCatching { URI(it) }.getOrNull() } ?: return null
        if (uri.port <= 0) return null
        return InetSocketAddress(InetAddress.getLoopbackAddress(), uri.port)
    }

    private fun pipe(from: InputStream, to: OutputStream, vararg closing: Socket) {
        try {
            from.copyTo(to, BUFFER)
        } catch (_: Exception) {
        } finally {
            closing.forEach { runCatching { it.close() } }
        }
    }

    private fun address(port: Int, token: String): String = "ws://127.0.0.1:$port/$token"

    private class PrefsStore(context: Context) : Store {
        private val prefs = context.getSharedPreferences("other_vault_link", Context.MODE_PRIVATE)
        override var npub: String?
            get() = prefs.getString("npub", null)
            set(v) { prefs.edit().putString("npub", v).apply() }
        override var port: Int
            get() = prefs.getInt("port", 0)
            set(v) { prefs.edit().putInt("port", v).apply() }
        override var until: Long
            get() = prefs.getLong("until", 0)
            set(v) { prefs.edit().putLong("until", v).apply() }
        override var token: String?
            get() = prefs.getString("token", null)
            set(v) { prefs.edit().putString("token", v).apply() }
    }

    private companion object {
        const val TAG = "OtherVaultLink"
        const val CONNECT_TIMEOUT_MS = 10_000
        const val BUFFER = 16 * 1024
        const val REQUEST_LINE_TIMEOUT_MS = 10_000
        const val MAX_REQUEST_LINE = 8 * 1024

        /** 32 random bytes, hex: the per-link secret in the address. */
        fun newToken(): String {
            val bytes = ByteArray(32).also { java.security.SecureRandom().nextBytes(it) }
            return bytes.joinToString("") { "%02x".format(it) }
        }

        /** One request line up to and with its LF, read a byte at a time so nothing after it is consumed. */
        fun readLine(input: InputStream): String? {
            val out = java.io.ByteArrayOutputStream()
            while (out.size() < MAX_REQUEST_LINE) {
                val b = input.read()
                if (b < 0) return null
                out.write(b)
                if (b == '\n'.code) return out.toString(Charsets.ISO_8859_1.name())
            }
            return null
        }
    }
}

/**
 * [line] (an HTTP request line, with its line end) with the leading `/<token>` taken out of the path, or null when
 * the path doesn't start with it: `GET /<token> HTTP/1.1` is `GET / HTTP/1.1`, `/<token>/x?y` is `/x?y`.
 */
internal fun withoutToken(line: String, token: String): String? {
    val parts = line.split(' ')
    if (parts.size != 3 || token.isEmpty()) return null
    val path = parts[1]
    val prefix = "/$token"
    if (path.length < prefix.length) return null
    val head = path.substring(0, prefix.length)
    if (!java.security.MessageDigest.isEqual(head.toByteArray(), prefix.toByteArray())) return null
    val rest = path.substring(prefix.length)
    val stripped = when {
        rest.isEmpty() -> "/"
        rest.startsWith("/") -> rest
        rest.startsWith("?") -> "/$rest"
        else -> return null  // /<token>more is another path
    }
    return "${parts[0]} $stripped ${parts[2]}"
}
