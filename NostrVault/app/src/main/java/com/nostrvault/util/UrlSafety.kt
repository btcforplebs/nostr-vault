package com.nostrvault.util

import java.net.Inet6Address
import java.net.InetAddress

/**
 * SSRF guard for fetching attacker-controlled URLs (e.g. link previews built from
 * note content).
 *
 * The app runs an on-device Nostr relay, Blossom server, and Haven bridge on
 * `https://localhost:<port>`, and may sit on a LAN. Without a
 * guard, a hostile note containing `http://127.0.0.1:<relayPort>/...` (or a public
 * URL that 302-redirects there) would make the app issue requests to its own
 * internal services or to other LAN hosts.
 *
 * Usage: validate every URL before fetching it AND after every redirect hop.
 * Fails closed — anything that can't be resolved/parsed is treated as unsafe.
 */
object UrlSafety {

    /** True if [rawUrl] is an http(s) URL whose host is not internal/private. */
    fun isSafeRemoteUrl(rawUrl: String): Boolean {
        val host = try {
            val uri = java.net.URI(rawUrl)
            val scheme = uri.scheme?.lowercase()
            if (scheme != "http" && scheme != "https") return false
            uri.host ?: return false
        } catch (_: Exception) {
            return false
        }
        return !isBlockedHost(host)
    }

    /** True if [host] is loopback / link-local / private / ULA / multicast / a special name. */
    fun isBlockedHost(host: String): Boolean {
        val h = host.lowercase().trim().removeSurrounding("[", "]")
        if (h.isEmpty()) return true
        if (h == "localhost" || h.endsWith(".localhost")) return true

        return try {
            // Resolve ALL addresses; reject if ANY is internal (defends against a
            // hostname that resolves to a private IP).
            InetAddress.getAllByName(h).any { isInternalAddress(it) }
        } catch (_: Exception) {
            true // fail closed on resolution failure
        }
    }

    /** True if [addr] is loopback / link-local / private / ULA / multicast / any-local. */
    fun isInternalAddress(addr: InetAddress): Boolean = with(addr) {
        if (isLoopbackAddress || isAnyLocalAddress || isLinkLocalAddress ||
            isSiteLocalAddress || isMulticastAddress
        ) {
            return true
        }
        // IPv6 unique-local addresses (fc00::/7) are not covered by isSiteLocalAddress.
        if (this is Inet6Address) {
            val b0 = address.getOrNull(0)?.toInt() ?: return true
            if ((b0 and 0xFE) == 0xFC) return true
        }
        return false
    }
}
