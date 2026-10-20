package com.nostrvault.relay

import java.io.File

/**
 * Relays that were once defaults and no longer answer. Checked from this
 * network on 2026-10-12: nos.lol and nostr.mom time out on the handshake and
 * offchain.pub refuses the connection.
 *
 * Only the defaults were changed in the code. A saved config that named one
 * of them keeps it, and a dead relay at the head of a list is worse than a
 * missing one: several features ask only the first few relays of a list
 * (`readRelays.take(3)`, `take(1)`), so one dead entry near the front means
 * that feature asks nobody. [droppingOnce] removes them from every saved
 * list once, on load. Same as iOS HavenConfig's migration.
 */
object DeadRelays {
    /** Hosts to drop; matched on the host, so any spelling or trailing slash goes too. */
    val HOSTS: Set<String> = setOf("nos.lol", "nostr.mom", "offchain.pub")

    fun isDead(url: String): Boolean {
        val host = url.trim().substringAfter("://").substringBefore('/').substringBefore(':').lowercase()
        return host in HOSTS
    }

    /** [relays] without the dead ones; the same list instance when nothing was dropped. */
    fun prune(relays: List<String>): List<String> {
        if (relays.none(::isDead)) return relays
        return relays.filterNot(::isDead)
    }

    /**
     * [config] with the dead relays removed from each saved relay list. A list
     * the pruning would empty goes back to its default instead, so a user whose
     * only read relay was nos.lol is not left with none. The blocked list is
     * untouched: blocking a dead relay is still a choice.
     */
    fun dropping(config: HavenConfig): HavenConfig {
        fun pruned(list: List<String>?, default: List<String>?): List<String>? {
            if (list == null) return null
            val kept = prune(list)
            return if (kept.isEmpty() && list.isNotEmpty()) default else kept
        }
        val inbox = pruned(config.inboxRelays, HavenConfig.DEFAULT_READ_RELAYS)
        val feed = pruned(config.feedRelays, HavenConfig.DEFAULT_READ_RELAYS)
        val dms = pruned(config.dmRelays, HavenConfig.DEFAULT_DM_RELAYS)!!
        val blastr = pruned(config.blastrRelays, RelayConfiguration.FALLBACK_WRITE_RELAYS)!!
        val import = pruned(config.importSeedRelays, HavenConfig().importSeedRelays)!!
        val search = pruned(config.searchRelays, null)
        if (inbox === config.inboxRelays && feed === config.feedRelays && dms === config.dmRelays &&
            blastr === config.blastrRelays && import === config.importSeedRelays && search === config.searchRelays
        ) return config
        return config.copy(
            inboxRelays = inbox,
            feedRelays = feed,
            dmRelays = dms,
            blastrRelays = blastr,
            importSeedRelays = import,
            searchRelays = search,
        )
    }

    /**
     * [dropping], the first time only: [marker] records that it ran, so a
     * user who adds one of these relays back keeps it on the next launch.
     */
    fun droppingOnce(config: HavenConfig, marker: File): HavenConfig {
        if (marker.exists()) return config
        val pruned = dropping(config)
        runCatching { marker.writeText("pruned\n") }
        return pruned
    }
}
