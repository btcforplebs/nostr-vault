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
    /**
     * My Devices as the engine's allowlist: valid mesh npubs, once each, never this phone's own, and only the owner's.
     * A device another account linked belongs to that account (Logen 2026-11-05), so it must not reach the owner's
     * relay port; it gets the door like everyone else (Tron, #1736; the web's ownersForAccount, #1726).
     */
    fun ownDevices(config: HavenConfig, ownNpub: String?): List<String> =
        (config.fipsPeers + listOfNotNull(config.homeVaultNpub))
            .map { it.trim() }
            .filter { MyDevicesRules.isMeshNpub(it) && it != ownNpub && !othersDevice(config, it) }
            .distinct()

    /** Linked while another account was active. Unlabelled and older devices ("" linkedBy) stay the owner's. */
    private fun othersDevice(config: HavenConfig, npub: String): Boolean =
        config.fipsMesh.devices.any { it.npub == npub && !MyDevicesRules.isOwners(it.linkedBy, config.ownerNpub) }

    /** Start options. [maxServeBytes] is what this sharing session may still send. */
    fun options(config: HavenConfig, ownNpub: String?, maxServeBytes: Long): FipsStartOptions {
        val own = ownDevices(config, ownNpub)
        return FipsStartOptions(
            // Valid npubs only: a typo typed by hand into the config used to stop the engine.
            // Only the owner's: dialing another account's device would hand it this phone's address.
            peers = config.fipsPeers.map { it.trim() }.filter { MyDevicesRules.isMeshNpub(it) && !othersDevice(config, it) }.distinct(),
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
     * Whether a running engine that started with [started] (and [startedHasLinkedPhone]) must restart for [config]:
     * anything it takes at start changed (peers, own devices, finder relays, middle server), or a phone became or
     * stopped being linked, which turns the own-devices share on or off. The serve allowance is left out: a restart
     * carries it over anyway. No record of a start (null) restarts, as before.
     */
    fun restartNeeded(started: FipsStartOptions?, startedHasLinkedPhone: Boolean, config: HavenConfig, ownNpub: String?): Boolean {
        if (started == null) return true
        val now = options(config, ownNpub, maxServeBytes = 0)
        return now != started.copy(maxServeBytes = 0) || hasLinkedPhone(config) != startedHasLinkedPhone
    }

    /**
     * The port sharing exports: the relay, for own devices alone (none, when the list is empty); the
     * engine sends everyone else to the door ([FipsStartOptions.strangersPort]) and refuses the two
     * being one port.
     */
    /**
     * Share off, and a phone of the owner's is linked: this vault is shared with own devices anyway (relay port only,
     * the door for strangers stays shut), so that phone's sends arrive (Logen 2026-11-05, iPhone #1779
     * `shareWhileOpenIfWanted`). Share on is the full sharing it always was.
     */
    fun sharesWithLinkedPhones(config: HavenConfig): Boolean = !config.fipsShareRelay && hasLinkedPhone(config)

    /** A phone of the owner's is in My Devices, one that gets their sends ([MeshSendTargets]). */
    fun hasLinkedPhone(config: HavenConfig): Boolean = MeshSendTargets.of(config).any { it.role == DeviceRole.PHONE }

    @Suppress("UNUSED_PARAMETER")
    fun sharePort(config: HavenConfig, ownDevices: List<String>): Int = config.relayPort
}
