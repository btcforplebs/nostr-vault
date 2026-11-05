package com.nostrvault.fips

import com.nostrvault.relay.HavenConfig

/** A device of the owner's that gets their new notes and media over the mesh. */
internal data class MeshSendTarget(val npub: String, val role: DeviceRole, val notes: Boolean, val media: Boolean)

/**
 * Where [HomeVaultSender] sends: the home vault, then each Mac in My Devices, each with its own Send
 * notes / Send media switches (a home vault with no label gets both). A Mac takes the same owner-signed
 * Blossom upload and EVENT the home vault does. Pure for the tests.
 */
internal object MeshSendTargets {
    fun of(config: HavenConfig): List<MeshSendTarget> {
        // Linked devices belong to the account that linked them; the sender sends the owner's posts, so only the
        // owner's devices get them (Logen 2026-11-05).
        val owners = config.fipsMesh.devices.filter { MyDevicesRules.isOwners(it.linkedBy, config.ownerNpub) }
        val home = config.homeVaultNpub?.takeIf { h ->
            config.fipsMesh.devices.none { it.npub == h && !MyDevicesRules.isOwners(it.linkedBy, config.ownerNpub) }
        }
        val macs = owners
            .filter { it.role == DeviceRole.MAC && it.npub in config.fipsPeers && it.npub != home && MyDevicesRules.isMeshNpub(it.npub) }
            .distinctBy { it.npub }
            .map { MeshSendTarget(it.npub, DeviceRole.MAC, notes = it.sendNotes, media = it.sendMedia) }
        val homeLabel = home?.let { h -> config.fipsMesh.devices.firstOrNull { it.npub == h } }
        val homeTarget = home?.let { MeshSendTarget(it, DeviceRole.HOME_VAULT, notes = homeLabel?.sendNotes ?: true, media = homeLabel?.sendMedia ?: true) }
        return listOfNotNull(homeTarget) + macs
    }

    /** Whether a device in this role is sent anything, so its Send switches mean something. Phones and browsers are not. */
    fun receivesSends(role: DeviceRole): Boolean = role == DeviceRole.HOME_VAULT || role == DeviceRole.MAC

    /**
     * After queueing one item on each lane: drain if any lane took it, so one full or broken lane
     * does not hold up the others, and say "full" if any did not (Tron, #1025).
     */
    fun afterQueueing(queued: List<Boolean>): Pair<Boolean, Boolean> = queued.any { it } to !queued.all { it }

    /** How a target is named in the card's problem line. */
    fun label(role: DeviceRole): String = if (role == DeviceRole.MAC) "Home vault · full history" else "Home vault · new posts"

    /** The same, mid-sentence: "the home vault", "your Mac". */
    fun destination(role: DeviceRole): String = if (role == DeviceRole.MAC) "your home vault" else "the home vault"
}
