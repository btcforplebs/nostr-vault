package com.nostrvault.relay

import android.content.Context
import java.io.File

/**
 * The WOT tab's rebuild when the vault is an outside relay (Citrine, or any
 * relay picked in Settings > Use External Relay). The embedded relay never
 * starts in that mode, so [HavenBridge.refreshWot] has nothing to run in and
 * answered "Relay isn't running". This hands the engine the same env a relay
 * start would, then asks it to build the web reading your own follow list from
 * the outside relay ([HavenBridge.refreshWotFromRelay]). The web lands in the
 * same wot_cache.json, so the tab and the feeds read it as usual.
 */
object ExternalWotRebuild {
    /** The outside relay to read your follow list from, or null when the vault is our own relay. */
    fun relayURL(config: HavenConfig): String? =
        if (config.useExternalRelay) config.nostrURL?.takeIf { it.isNotBlank() } else null

    /**
     * Starts the rebuild. True when it started or one is already running,
     * false when the vault isn't on an outside relay or the engine refused.
     * Writes files and calls the engine: call off the main thread.
     */
    fun start(context: Context, config: HavenConfig): Boolean {
        val url = relayURL(config) ?: return false
        if (!HavenBridge.isLoaded) return false
        val relayDataDir = File(context.filesDir, "relay_data")
        RelayConfiguration.ensureDirectories(relayDataDir)
        // No dial: the Mac mesh relay only changes the broadcast list, which
        // a web rebuild never uses. The next relay start rewrites these anyway.
        val inputs = RelayConfiguration.LaunchInputs(
            env = RelayConfiguration.generateEnvDictionary(config, relayDataDir),
            importSeedRelays = config.vaultSeedRelays,
            blastrRelays = RelayConfiguration.blastrRelays(config, RelayConfiguration.macMeshRelay),
            dmRelays = config.dmRelays,
            whitelist = VaultWhitelist.npubs(config),
            accountReach = config.relayAccountReach,
        )
        for ((key, value) in inputs.env) HavenBridge.setEnv(key, value)
        RelayConfiguration.writeRelayListFiles(config, inputs, relayDataDir)
        return HavenBridge.refreshWotFromRelay(url)
    }
}
