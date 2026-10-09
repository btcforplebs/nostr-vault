package com.nostrvault.ui.navigation

import androidx.compose.runtime.staticCompositionLocalOf

/**
 * Opens the feed for a hashtag ("bitcoin", no #). Provided around the nav host,
 * so every [com.nostrvault.ui.components.NostrContentText] can route a tapped
 * #hashtag without each screen threading a callback through. Null (previews,
 * anything outside the nav host) leaves hashtags as plain text.
 */
val LocalOpenHashtag = staticCompositionLocalOf<((String) -> Unit)?> { null }

/** The tag a hashtag feed asks relays for (iOS `HashtagLink`). */
object HashtagLink {
    /**
     * Lowercased, without leading #s: NIP-24 says `t` tags are lowercase.
     * Null when nothing is left.
     */
    fun normalize(tag: String): String? =
        tag.trim().trimStart('#').lowercase().takeIf { it.isNotEmpty() }

    /**
     * The tag a search for [query] names, when it is a single "#tag" (iOS: a
     * `#`, then more than one character, no spaces, no second `#`). Anything
     * else is a word search.
     */
    fun fromSearchQuery(query: String): String? {
        val q = query.trim()
        if (!q.startsWith("#") || q.length <= 2) return null
        val rest = q.substring(1)
        if (rest.any { it.isWhitespace() || it == '#' }) return null
        return normalize(rest)
    }
}
