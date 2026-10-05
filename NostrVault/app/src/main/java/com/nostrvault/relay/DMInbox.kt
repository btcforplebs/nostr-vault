package com.nostrvault.relay

/**
 * The DM inbox list — one list for every device. It is where other people
 * send this account's DMs (published as kind 10050), where this account's own
 * sent copies go, and where every device reads DMs from. The owner's Haven
 * inbox (the Mac relay) comes first, then [HavenConfig.dmRelays].
 *
 * Mirrors the iOS/macOS HavenConfig DM inbox helpers (nostr-vault #210).
 */
object DMInbox {

    /** What launch should do with the DM inbox list. */
    enum class SyncAction {
        /** Take the published list (and its timestamp) as this device's own. */
        ADOPT,
        /** Publish this device's list: nothing is published, or ours is newer. */
        PUBLISH,
        /** Already in step. */
        NONE,
    }

    /** Trims whitespace and trailing slashes so one relay typed two ways compares equal. */
    fun normalizedRelayURL(raw: String): String = raw.trim().trimEnd('/')

    fun merged(havenInbox: String, dmRelays: List<String>): List<String> {
        val seen = HashSet<String>()
        return (listOf(havenInbox) + dmRelays)
            .map(::normalizedRelayURL)
            .filter { it.isNotEmpty() && seen.add(it.lowercase()) }
    }

    /**
     * Relays a just-posted event also goes to beyond the blastr relays: a
     * kind 10050 goes to the DM relays it names, where senders look for it.
     * Entries already in [alreadySending] (compared normalized) are left out.
     * Mirrors iOS RelayConfiguration.directBroadcastRelays (nostr-vault #224).
     */
    fun extraBroadcastRelays(kind: Int, tags: List<List<String>>, alreadySending: List<String>): List<String> {
        if (kind != 10050) return emptyList()
        val seen = alreadySending.map { normalizedRelayURL(it).lowercase() }.toHashSet()
        return tags
            .filter { it.size >= 2 && it[0] == "relay" }
            .map { normalizedRelayURL(it[1]) }
            .filter { it.isNotEmpty() && seen.add(it.lowercase()) }
    }

    /**
     * The Mac relay's inbox as a DM relay, or "" when there is none. Only a
     * public address counts: the list it joins is published for other
     * people, and a plain ws:// or home-network address is unreachable to them.
     */
    fun havenInboxURL(macRelayURL: String, macRelayNormalizedBase: String): String {
        if (macRelayNormalizedBase.isEmpty()) return ""
        val typed = macRelayURL.trim().lowercase()
        if (typed.startsWith("ws://") || typed.startsWith("http://")) return ""
        if (isPrivateNetworkHost(macRelayNormalizedBase)) return ""
        return normalizedRelayURL("wss://$macRelayNormalizedBase/inbox")
    }

    /**
     * `published` is the newest kind 10050 found (null = none found),
     * `publishedAt` its created_at. Lists are compared as sets, so two devices
     * ordering the same relays differently don't republish over each other.
     */
    fun syncAction(local: List<String>, localUpdatedAt: Long?, published: List<String>?, publishedAt: Long?): SyncAction {
        if (published == null || publishedAt == null) {
            // Nothing found. For a list never set, nothing is published, so
            // publish one. A device that has synced before more likely just
            // couldn't reach the relays, and publishing would overwrite a
            // newer list it never saw.
            return if (localUpdatedAt == null) SyncAction.PUBLISH else SyncAction.NONE
        }
        val localAt = localUpdatedAt ?: 0L
        if (publishedAt > localAt) return SyncAction.ADOPT
        if (localAt > publishedAt) return SyncAction.PUBLISH
        val a = local.map { normalizedRelayURL(it).lowercase() }.toSet()
        val b = published.map { normalizedRelayURL(it).lowercase() }.toSet()
        return if (a == b) SyncAction.NONE else SyncAction.PUBLISH
    }

    /**
     * True for an address only this network can reach: loopback, private and
     * link-local IPv4/IPv6, CGNAT (Tailscale's 100.64.0.0/10), localhost,
     * home-network suffixes, Tailscale .ts.net names and bare dotless names.
     * `hostPort` may carry a port and a path.
     */
    fun isPrivateNetworkHost(hostPort: String): Boolean {
        var host = hostPort.lowercase().substringBefore('/')
        host = if (host.startsWith("[")) {
            host.drop(1).substringBefore(']')
        } else if (host.count { it == ':' } == 1) {
            host.substringBefore(':')
        } else host
        host = host.trimEnd('.')
        if (host.startsWith("::ffff:")) {
            val v4 = host.removePrefix("::ffff:")
            if (v4.contains('.')) return isPrivateNetworkHost(v4)
        }
        if (host.isEmpty() || host == "localhost") return true
        if (listOf(".localhost", ".local", ".lan", ".home.arpa", ".internal", ".ts.net").any { host.endsWith(it) }) return true
        if (host.contains(':')) {
            return host == "::1" || host == "::" || host.startsWith("fc") || host.startsWith("fd") ||
                host.startsWith("fe8") || host.startsWith("fe9") || host.startsWith("fea") || host.startsWith("feb")
        }
        val octets = host.split('.').map { it.toIntOrNull() }
        if (octets.size == 4 && octets.all { it != null }) {
            val a = octets[0]!!
            val b = octets[1]!!
            return a == 10 || a == 127 || a == 0 ||
                (a == 172 && b in 16..31) || (a == 192 && b == 168) || (a == 169 && b == 254) ||
                (a == 100 && b in 64..127)
        }
        return !host.contains('.')
    }
}
