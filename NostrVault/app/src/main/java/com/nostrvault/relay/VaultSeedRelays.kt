package com.nostrvault.relay

/**
 * The vault reads only the owner's own relay list (Logen 2026-11-08): their
 * read relays, their write relays, and any extra importing relays they picked
 * themselves. There is no hidden seed list any more; builds before this
 * filled [HavenConfig.importSeedRelays] with a fixed three or four public
 * relays the owner never chose. Twin of iOS VaultSeedRelays.swift.
 */
object VaultSeedRelays {
    /** The import seed lists earlier builds shipped as defaults (iOS and Android). */
    val LEGACY_IMPORT_DEFAULTS: Set<String> = setOf(
        "wss://relay.primal.net",
        "wss://relay.damus.io",
        "wss://relay.btcforplebs.com",
        "wss://nostr-pub.wellorder.net",
        "wss://nos.lol",
        "wss://nostr.mom",
        "wss://relay.snort.social",
    )

    /** Read relays, then write relays, then the owner's own picks, de-duplicated (case and trailing slash ignored). */
    fun vaultSeeds(read: List<String>, write: List<String>, chosen: List<String>): List<String> {
        val seen = HashSet<String>()
        val out = ArrayList<String>()
        for (raw in read + write + chosen) {
            val trimmed = raw.trim()
            if (trimmed.isEmpty() || !seen.add(key(trimmed))) continue
            out.add(trimmed)
        }
        return out
    }

    /**
     * The importing relays the owner picked, from a saved list: their own
     * read and write relays and the Mac relay are left out (the vault reads
     * those anyway), and a remainder made only of old defaults is dropped.
     */
    fun chosenImportRelays(saved: List<String>, own: List<String>, mac: String): List<String> {
        val ownKeys = own.map(::key).toSet()
        val macKey = if (mac.isEmpty()) null else key(mac)
        val rest = saved.filter { url -> key(url).let { it.isNotEmpty() && it !in ownKeys && it != macKey } }
        val legacy = LEGACY_IMPORT_DEFAULTS.map(::key).toSet()
        return if (rest.all { key(it) in legacy }) emptyList() else rest
    }

    /** [config] with only the owner's picks kept as import seeds. */
    fun keepingOnlyPicks(config: HavenConfig): HavenConfig {
        val picks = chosenImportRelays(
            config.importSeedRelays,
            own = (config.feedRelays ?: config.activeInboxRelays) + config.blastrRelays,
            mac = config.macRelayWssURL,
        )
        return if (picks == config.importSeedRelays) config else config.copy(importSeedRelays = picks)
    }

    private fun key(url: String): String = url.trim().lowercase().trimEnd('/')
}
