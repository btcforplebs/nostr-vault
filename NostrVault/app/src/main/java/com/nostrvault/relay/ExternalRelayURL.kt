package com.nostrvault.relay

/**
 * Normalizes a user-typed relay address: trims it, drops trailing slashes and
 * adds a scheme when none was given. Two kinds of address are accepted:
 *
 * - A relay app on this phone (Citrine): `ws://` or `wss://` on 127.0.0.1 or
 *   localhost. A bare address gets `ws://`.
 * - A relay somewhere else (Nostr Vault for Mac on a domain): `wss://` only.
 *   A bare address gets `wss://`.
 *
 * Plain `ws://` to any other host is refused: network_security_config only
 * allows cleartext to loopback, so it would validate and then silently fail.
 * `.onion` is refused too; the app has no Tor client.
 */
fun normalizeExternalRelayURL(raw: String): String? =
    normalizeExternalURL(raw, secure = "wss://", plain = "ws://")

/** Same as [normalizeExternalRelayURL] for a Blossom server (`https://`, or `http://` on this phone). */
fun normalizeExternalBlossomURL(raw: String): String? =
    normalizeExternalURL(raw, secure = "https://", plain = "http://")

private val IPV4_LITERAL = Regex("^(\\d{1,3})\\.(\\d{1,3})\\.\\d{1,3}\\.\\d{1,3}$")

/**
 * Whether [url] points at this phone or a private network: loopback, the
 * RFC 1918 ranges, Tailscale's 100.64/10, `.local` and `.ts.net` names. A
 * link to such a host only opens for its owner, so it must never be the
 * only link a post carries. Hostnames are matched as IP literals, so
 * `10.example.com` is public.
 */
fun isPrivateNetworkURL(url: String): Boolean {
    val host = runCatching { java.net.URI(url).host }.getOrNull()?.lowercase()?.trim('[', ']') ?: return false
    if (host == "localhost" || host == "::1" || host.endsWith(".local") || host.endsWith(".ts.net")) return true
    val m = IPV4_LITERAL.matchEntire(host) ?: return false
    val a = m.groupValues[1].toInt()
    val b = m.groupValues[2].toInt()
    return a == 127 || a == 10 || (a == 192 && b == 168) || (a == 172 && b in 16..31) ||
        (a == 100 && b in 64..127)
}

private fun normalizeExternalURL(raw: String, secure: String, plain: String): String? {
    var url = raw.trim().trimEnd('/')
    if (url.isEmpty() || url.any { it.isWhitespace() }) return null
    val lower = url.lowercase()
    if ("://" !in lower) {
        val bareHost = lower.substringBefore('/').substringBefore(':')
        url = (if (bareHost == "127.0.0.1" || bareHost == "localhost") plain else secure) + url
    } else if (!lower.startsWith(secure) && !lower.startsWith(plain)) {
        return null
    }
    val uri = runCatching { java.net.URI(url) }.getOrNull() ?: return null
    val host = uri.host?.lowercase() ?: return null
    if (host.endsWith(".onion")) return null
    val onDevice = host == "127.0.0.1" || host == "localhost"
    if (!onDevice && !url.lowercase().startsWith(secure)) return null
    return url
}
