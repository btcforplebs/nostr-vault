package com.nostrvault.ui.components

import java.net.URI
import java.net.URLEncoder

/**
 * The URL to download a profile picture from: a small copy made by a resizing
 * service instead of the original. Port of iOS AvatarThumbnail.swift.
 *
 * Profile pictures are often far larger than an avatar needs. Across 238 real
 * follows the originals weighed 187 MB (one GIF was 25 MB); the same pictures
 * at 256 px weigh 3.8 MB. Primal and nostr.build, which host most of them, have
 * no resize option that works for GIFs, so a resizing service is the only way
 * to get small copies.
 *
 * The service sees which pictures are loaded. If it can't fetch or resize a
 * picture, `default` redirects to the original, so a picture that loaded before
 * still loads. Callers keep caching under the original URL.
 * https://wsrv.nl/docs/
 */
internal object AvatarThumbnail {
    const val HOST = "wsrv.nl"

    /** Matches iOS, and covers the largest avatar (80dp at 3x). */
    const val PIXEL_SIZE = 256

    fun url(original: String): String {
        val uri = runCatching { URI(original) }.getOrNull() ?: return original
        val scheme = uri.scheme?.lowercase()
        if (scheme != "https" && scheme != "http") return original
        val host = uri.host?.lowercase() ?: return original
        if (!isPublic(host)) return original
        val encoded = encode(original)
        return "https://$HOST/?url=$encoded&w=$PIXEL_SIZE&h=$PIXEL_SIZE&fit=inside&we&output=webp&default=$encoded"
    }

    /**
     * The service can't reach the device relay, the LAN or Tor, and shouldn't
     * learn their addresses.
     */
    private fun isPublic(host: String): Boolean {
        if (host == HOST || host == "localhost" || host.endsWith(".local") || host.endsWith(".onion")) {
            return false
        }
        if (host.contains(":") || host.startsWith("[")) return false // IPv6 literal
        val parts = host.split(".")
        val octets = parts.mapNotNull { it.toIntOrNull() }
        if (parts.size == 4 && octets.size == 4) {
            val (a, b) = octets[0] to octets[1]
            return when {
                a == 10 || a == 127 || a == 0 -> false
                a == 169 && b == 254 -> false
                a == 192 && b == 168 -> false
                a == 172 && b in 16..31 -> false
                a == 100 && b in 64..127 -> false
                else -> true
            }
        }
        return true
    }

    /**
     * Percent-encodes everything but unreserved characters, so the original's
     * own `?`, `&` and `=` stay inside the `url` value.
     */
    private fun encode(s: String): String =
        URLEncoder.encode(s, "UTF-8")
            .replace("+", "%20")
            .replace("*", "%2A")
            .replace("%7E", "~")
}
