package com.nostrvault.relay

/**
 * NIP-65 kind 10002: the relay list other clients use for this account. It is
 * the grid's Read and Write columns, so the world sees what the owner actually
 * uses. Mirrors iOS `HavenConfig.publicRelayListTags`.
 */
object PublicRelayList {

    /**
     * The owner's own relays go first with no marker, which NIP-65 reads as
     * both read and write, so they always stay in Write. Then each relay in
     * both lists has no marker, and one in only one list is marked "read" or
     * "write". Only wss:// relays others can reach are listed, once each.
     */
    fun tags(ownRelays: List<String>, read: List<String>, write: List<String>): List<List<String>> {
        fun publishable(raw: String): String? {
            val url = DMInbox.normalizedRelayURL(raw)
            if (!url.lowercase().startsWith("wss://")) return null
            val hostPort = url.drop("wss://".length)
            if (hostPort.isEmpty() || DMInbox.isPrivateNetworkHost(hostPort)) return null
            return url
        }
        val readKeys = read.mapNotNull(::publishable).map { it.lowercase() }.toSet()
        val writeKeys = write.mapNotNull(::publishable).map { it.lowercase() }.toSet()
        val seen = HashSet<String>()
        val tags = mutableListOf<List<String>>()
        for (url in ownRelays.mapNotNull(::publishable)) {
            if (seen.add(url.lowercase())) tags.add(listOf("r", url))
        }
        for (url in (read + write).mapNotNull(::publishable)) {
            val key = url.lowercase()
            if (!seen.add(key)) continue
            tags.add(
                when {
                    key in readKeys && key in writeKeys -> listOf("r", url)
                    key in readKeys -> listOf("r", url, "read")
                    else -> listOf("r", url, "write")
                },
            )
        }
        return tags
    }
}
