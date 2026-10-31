package com.nostrvault.relay

import java.io.File

/**
 * relay.damus.io left the default import-seed list on 2026-10-31 (it bans
 * and publicly lists busy IPs). A saved config still holding the old default
 * list exactly gets the new one, once; a list the owner edited is theirs.
 * The DM list is left alone: it is published (kind 10050), so others send
 * DMs to those relays and the inbox must keep reading them.
 */
object DamusDefaults {
    internal val OLD_IMPORT_SEED = listOf(
        "wss://relay.primal.net",
        "wss://relay.damus.io",
        "wss://relay.btcforplebs.com",
        "wss://nostr-pub.wellorder.net",
    )

    fun dropping(config: HavenConfig): HavenConfig =
        if (config.importSeedRelays == OLD_IMPORT_SEED) config.copy(importSeedRelays = HavenConfig().importSeedRelays) else config

    fun droppingOnce(config: HavenConfig, marker: File): HavenConfig {
        if (marker.exists()) return config
        val out = dropping(config)
        runCatching { marker.writeText("done\n") }
        return out
    }
}
