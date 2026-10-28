package com.nostrvault.data.model

import com.nostrvault.relay.blossomUploadServer

/**
 * A Blossom server offered under Media Servers › Suggested, so people can add
 * one with a tap instead of knowing an address.
 */
data class SuggestedMediaServer(
    val url: String,
    /** One plain line: free or paid, and the limit that matters. */
    val note: String,
) {
    val host: String get() = runCatching { java.net.URI(url).host }.getOrNull() ?: url
}

object SuggestedMediaServers {
    /**
     * Checked live on 2026-10-28: each answers, keeps files, and the free
     * ones take uploads from any npub. Left out on purpose: nostr.download and
     * 24242.io delete files nobody opens, which is wrong for a vault. Prices
     * and limits drift, so re-check this list before a release.
     * Same list as iOS `SuggestedMediaServers.swift` and web `suggested-servers.js`.
     */
    val all: List<SuggestedMediaServer> = listOf(
        SuggestedMediaServer("https://blossom.primal.net", "Free"),
        SuggestedMediaServer("https://blossom.nostr.build", "Free up to 20 MB a file · paid plans from \$18 a year"),
        SuggestedMediaServer("https://nostr.media", "Free"),
        SuggestedMediaServer("https://blossom.azzamo.media", "Free tier · paid from \$3 a month"),
        SuggestedMediaServer("https://blossom.jumble.social", "Free up to 20 MB a file"),
        SuggestedMediaServer("https://nostrmedia.com", "Paid only · from \$2.99 a month"),
    )

    /**
     * The suggestions not already in [servers]. A server counts as added when
     * it uploads to the same place, so a typed `nostr.build` hides
     * `blossom.nostr.build`.
     */
    fun notYetAdded(servers: List<String>): List<SuggestedMediaServer> {
        val added = servers.mapNotNull(::uploadHost).toSet()
        return all.filterNot { it.host in added }
    }

    private fun uploadHost(server: String): String? {
        val target = blossomUploadServer(server) ?: return null
        val withScheme = if ("://" in target) target else "https://$target"
        return runCatching { java.net.URI(withScheme).host?.lowercase() }.getOrNull()
    }
}
