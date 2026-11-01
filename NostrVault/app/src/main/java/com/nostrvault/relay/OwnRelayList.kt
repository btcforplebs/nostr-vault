package com.nostrvault.relay

/**
 * The owner's own relay list (kind 10002) is the read and write relays
 * (Logen 2026-11-01): at setup, at launch and whenever a newer list
 * arrives. The starter relays are only for an account with no list. An edit
 * made in Settings > Relays is kept until a newer list is published. Adopting
 * never publishes anything. Same as iOS HavenConfig.adoptRelayList.
 */
object OwnRelayList {
    /** Every relay the app has shipped as a read or write default, current or former, by host. */
    val SHIPPED_HOSTS: Set<String> = setOf(
        "relay.primal.net", "relay.damus.io", "relay.snort.social", "relay.btcforplebs.com",
        "nostr-pub.wellorder.net", "nos.lol", "nostr.mom", "offchain.pub", "relay.nos.social",
        "nostr.wine", "nostr.land", "relay.nostr.build",
    )

    fun host(url: String): String =
        url.trim().substringAfter("://").substringBefore('/').substringBefore(':').lowercase()

    /**
     * True when the lists hold only relays the app shipped (entries no one
     * else can reach, such as the Haven relay or this phone, don't count):
     * the owner never set relays of their own here.
     */
    fun looksUnedited(read: List<String>, write: List<String>): Boolean =
        (read + write).filter(RelayDraft::listable).all { host(it) in SHIPPED_HOSTS }

    /** Whether a list dated [publishedAt] replaces this device's: newer than the last change here. */
    fun adopts(localUpdatedAt: Long?, publishedAt: Long): Boolean = publishedAt > (localUpdatedAt ?: 0L)

    /**
     * [config] with the published list ([read], [write]) as its read and write
     * relays, when [adopts] says so. Relays no one else can reach, dead ones
     * and blocked ones (by the Never connect rule, every path on a blocked
     * host) are left out: the write list goes to the relay, which has no
     * blocklist of its own. A side that ends up empty keeps what it had. A
     * copy dated [com.nostrvault.service.ListMerge.MAX_SKEW] or more ahead of
     * [now] is ignored: it would stay the newest on the relays and undo every
     * later edit here.
     *
     * An install from before [HavenConfig.relayListUpdatedAt] has no stamp.
     * Its lists count as never edited when they hold only shipped relays;
     * otherwise they were edited here, so they are stamped [now] and kept
     * until a newer list is published.
     */
    fun adopting(config: HavenConfig, read: List<String>, write: List<String>, publishedAt: Long, now: Long): HavenConfig {
        if (!com.nostrvault.service.ListMerge.notAhead(publishedAt, now)) return config
        val lists = RelayMatrix.lists(config)
        if (config.relayListUpdatedAt == null && !looksUnedited(lists.read, lists.write)) {
            return config.copy(relayListUpdatedAt = now)
        }
        if (!adopts(config.relayListUpdatedAt, publishedAt)) return config
        val blocked = config.blockedRelays
        fun usable(list: List<String>): List<String> {
            val seen = HashSet<String>()
            return list.map(DMInbox::normalizedRelayURL).filter {
                RelayDraft.listable(it) && !DeadRelays.isDead(it) &&
                    !RelayBlocklist.isBlocked(it, blocked) && seen.add(RelayMatrix.key(it))
            }
        }
        val newRead = usable(read)
        val newWrite = usable(write)
        return config.copy(
            feedRelays = newRead.ifEmpty { config.feedRelays },
            blastrRelays = newWrite.ifEmpty { config.blastrRelays },
            relayListUpdatedAt = publishedAt,
        )
    }
}
