package com.nostrvault.fips

import com.nostrvault.relay.HavenConfig

/** A device of the owner's that gets their new notes and media over the mesh. */
internal data class MeshSendTarget(val npub: String, val role: DeviceRole, val notes: Boolean, val media: Boolean)

/**
 * Where [HomeVaultSender] sends: the home vault, which gets everything, then each Mac in My Devices
 * with its own Send notes / Send media switches. A Mac takes the same owner-signed Blossom upload and
 * EVENT the home vault does. Pure for the tests.
 */
internal object MeshSendTargets {
    fun of(config: HavenConfig): List<MeshSendTarget> {
        val home = config.homeVaultNpub
        val macs = config.fipsMesh.devices
            .filter { it.role == DeviceRole.MAC && it.npub in config.fipsPeers && it.npub != home && MyDevicesRules.isMeshNpub(it.npub) }
            .distinctBy { it.npub }
            .map { MeshSendTarget(it.npub, DeviceRole.MAC, notes = it.sendNotes, media = it.sendMedia) }
        return listOfNotNull(home?.let { MeshSendTarget(it, DeviceRole.HOME_VAULT, notes = true, media = true) }) + macs
    }

    /**
     * After queueing one item on each lane: drain if any lane took it, so one full or broken lane
     * does not hold up the others, and say "full" if any did not (Tron, #1025).
     */
    fun afterQueueing(queued: List<Boolean>): Pair<Boolean, Boolean> = queued.any { it } to !queued.all { it }

    /** How a target is named in the card's problem line. */
    fun label(role: DeviceRole): String = if (role == DeviceRole.MAC) "Your Mac" else "Home vault"

    /** The same, mid-sentence: "the home vault", "your Mac". */
    fun destination(role: DeviceRole): String = if (role == DeviceRole.MAC) "your Mac" else "the home vault"
}
