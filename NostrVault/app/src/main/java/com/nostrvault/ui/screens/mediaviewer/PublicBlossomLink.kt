package com.nostrvault.ui.screens

/**
 * The link to share for a Blossom item: its own URL when it has one, otherwise
 * the first public mirror + sha256. Never a path on this phone.
 *
 * A server that lists the file at a URL without its hash (a bare host) gives
 * a link that opens nothing, so that URL is passed over for mirror + sha256.
 * An onion address gets http, as the relay's own links do (haven-go
 * getHTTPScheme): an onion service has no https certificate. Apple twin:
 * MediaShareLink.swift.
 */
internal fun publicBlossomLink(item: BlossomMediaItem, mirrors: List<String>): String {
    val own = item.displayUrl
    val ownNamesFile = item.sha256.isEmpty() || own.contains(item.sha256, ignoreCase = true)
    if (own.startsWith("http") && ownNamesFile) return overTor(own)
    val mirror = mirrors.firstOrNull { !it.contains("localhost") && !it.contains("127.0.0.1") }
    if (mirror != null && item.sha256.isNotEmpty()) return overTor("${mirror.trimEnd('/')}/${item.sha256}")
    return overTor(own)
}

/** https -> http for a .onion host; any other link is returned as is. */
internal fun overTor(link: String): String {
    if (!link.startsWith("https://", ignoreCase = true)) return link
    val host = link.substring(8).substringBefore('/').substringBefore('?').substringBefore('#')
        .substringAfterLast('@').substringBeforeLast(':').lowercase().trimEnd('.')
    return if (host.endsWith(".onion")) "http://" + link.substring(8) else link
}
