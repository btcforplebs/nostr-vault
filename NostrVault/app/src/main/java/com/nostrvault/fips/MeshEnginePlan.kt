package com.nostrvault.fips

import com.nostrvault.relay.HavenConfig

/**
 * Who the mesh engine lets in, and where it sends them, from the config. Pure for the tests; the
 * Mac's twin is MeshDevicesLogic.macEngineOptions.
 *
 * My Devices (fipsPeers, plus the home vault) are the engine's `own_devices`: only they get this
 * phone's address, since offers from anyone else go unanswered, and only they reach the relay port
 * while sharing. Everyone else, while sharing, reaches Haven's mesh door ([HavenConfig.meshPort]):
 * blob reads and owner-signed writes, capped, through the public seeds. A follow's vault is read
 * through the seeds with no dial (`read_anyone`). With no devices the engine is closed the same way:
 * it answers no one's offers, so the default install no longer gives its address away (Tron, #1030).
 */
internal object MeshEnginePlan {
    /** My Devices as the engine's allowlist: valid mesh npubs, once each, never this phone's own. */
    fun ownDevices(config: HavenConfig, ownNpub: String?): List<String> =
        (config.fipsPeers + listOfNotNull(config.homeVaultNpub))
            .map { it.trim() }
            .filter { MyDevicesRules.isMeshNpub(it) && it != ownNpub }
            .distinct()

    /** Start options. [maxServeBytes] is what this sharing session may still send. */
    fun options(config: HavenConfig, ownNpub: String?, maxServeBytes: Long): FipsStartOptions {
        val own = ownDevices(config, ownNpub)
        return FipsStartOptions(
            // Valid npubs only: a typo typed by hand into the config used to stop the engine.
            peers = config.fipsPeers.map { it.trim() }.filter { MyDevicesRules.isMeshNpub(it) }.distinct(),
            // FIPS Mesh → Advanced: the finder relays (the same three as iPhone and Mac by default) and the middle server.
            relays = config.fipsMesh.engineFinderRelays,
            publicSeeds = config.fipsMesh.middleServer == FipsMeshSettings.MIDDLE_PUBLIC,
            // LAN candidates: a device of yours is often on the same Wi-Fi, where the shared public address alone
            // does not connect. With own devices set, only they ever get an answer.
            lan = true,
            maxServeBytes = maxServeBytes,
            ownDevices = own,
            strangersPort = config.meshPort,
            // Reading a follow's vault: through the seeds, no dial, so it never gets this phone's address.
            // It also keeps own-devices mode on with an empty list, so the engine is never open.
            readAnyone = true,
        )
    }

    /**
     * The port sharing exports: the relay, for own devices alone (none, when the list is empty); the
     * engine sends everyone else to the door ([FipsStartOptions.strangersPort]) and refuses the two
     * being one port.
     */
    @Suppress("UNUSED_PARAMETER")
    fun sharePort(config: HavenConfig, ownDevices: List<String>): Int = config.relayPort
}
