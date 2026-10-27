package com.nostrvault.ui.navigation

/**
 * `https://nostrvault.app/p/<npub>`: the link Share profile hands out, and the
 * one a QR code on someone else's phone holds.
 *
 * Plain JVM so [DeepLinkRouter] and the setup wizard's "Who told you about
 * Nostr Vault?" step read it the same way, and unit tests can drive it.
 */
object ProfileWebLink {
    const val HOST = "nostrvault.app"

    /** The link for [npub]. */
    fun forNpub(npub: String): String = "https://$HOST/p/$npub"

    /**
     * The `npub1…` / `nprofile1…` / hex id in a `/p/` link, or null when [raw]
     * is not one. `www.` and plain http are accepted; anything after the id
     * (a trailing slash, a query, a fragment) is dropped.
     */
    fun idFrom(raw: String): String? {
        val s = raw.trim()
        // The site page's "Open in Nostr Vault" button: nostrvault://p/<npub>.
        if (s.startsWith("nostrvault://p/", ignoreCase = true)) {
            return s.substring("nostrvault://p/".length).substringBefore('?').substringBefore('#').trim('/')
                .takeIf { it.isNotBlank() && '/' !in it }
        }
        val rest = listOf("https://", "http://").firstOrNull { s.startsWith(it, ignoreCase = true) }
            ?.let { s.substring(it.length) } ?: return null
        val host = rest.substringBefore('/').lowercase()
        if (host != HOST && host != "www.$HOST") return null
        val path = rest.substringAfter('/', "").substringBefore('?').substringBefore('#')
        val segments = path.split('/').filter { it.isNotEmpty() }
        if (segments.size != 2 || segments[0] != "p") return null
        return segments[1].takeIf { it.isNotBlank() }
    }

    /**
     * The hex pubkey someone typed, pasted or scanned: a `/p/` link, a
     * `nostr:` URI, an npub, an nprofile or a 64-char hex key. Null for
     * anything else, so a bad paste never names a stranger.
     */
    fun pubkeyFrom(raw: String, decoder: NostrEntityDecoder): String? {
        val id = (idFrom(raw) ?: raw.trim().removePrefix("nostr:").substringBefore('?')).trim()
        val hex = when {
            id.startsWith("npub1", ignoreCase = true) -> decoder.npubToHex(id.lowercase())
            id.startsWith("nprofile1", ignoreCase = true) -> decoder.nprofileToHex(id.lowercase())
            id.length == 64 && id.all { it in '0'..'9' || it in 'a'..'f' || it in 'A'..'F' } -> id
            else -> null
        }
        return hex?.lowercase()
    }
}
