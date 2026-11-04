package com.nostrvault.relay

/**
 * The NIP-42 `relay` tag the embedded vault accepts for [url], one of its
 * [HavenConfig.localRelayURL]s.
 *
 * The socket is plain ws:// on loopback, but haven-go's ServiceURL is
 * "https://" + RELAY_URL + path (init.go relayServiceURL: the app always sets
 * RELAY_URL, so the scheme is https, http only for an .onion host), and the
 * AUTH check compares scheme, host and path. A ws:// tag therefore fails every
 * owner AUTH ("failed to authenticate"). iOS already signs wss://, because its
 * nostrURL is TLS. An external relay, or a URL that isn't this vault's, passes
 * through unchanged.
 */
fun HavenConfig.vaultAuthRelayTag(url: String): String {
    if (useExternalRelay) return url
    val host = relayURL.substringAfter("://").trimEnd('/')
    val base = nostrURL?.trimEnd('/') ?: return url
    if (host.isEmpty() || !url.startsWith(base)) return url
    val path = url.removePrefix(base).trimEnd('/')
    if (path.isNotEmpty() && !path.startsWith("/")) return url
    val scheme = if (host.substringBefore(':').endsWith(".onion")) "ws" else "wss"
    return "$scheme://$host$path"
}
