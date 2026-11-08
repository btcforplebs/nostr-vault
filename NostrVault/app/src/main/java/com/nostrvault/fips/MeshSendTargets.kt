package com.nostrvault.fips

import com.nostrvault.relay.HavenConfig

/** A device of the owner's on the mesh: one that gets their new notes and media, or (a phone) one Delete everywhere reaches. */
internal data class MeshSendTarget(val npub: String, val role: DeviceRole)

/**
 * Where [HomeVaultSender] sends: the mobile vault, then each Mac in My Devices. Every one gets both notes and media:
 * the per-device Send switches are gone, and phones are not sent to, as on iPhone (Logen 2026-11-08). A Mac takes the
 * same owner-signed Blossom upload and EVENT the mobile vault does. Pure for the tests.
 */
internal object MeshSendTargets {
    fun of(config: HavenConfig): List<MeshSendTarget> = ownDevices(config).filter { receivesSends(it.role) }

    /**
     * The owner's mobile vault, Macs and linked phones, as [of] sent to before phones stopped getting sends. A phone
     * still holds what was sent or uploaded on it, so Delete everywhere reaches it, and a linked phone still keeps
     * own-devices sharing on ([MeshEnginePlan.hasLinkedPhone]).
     */
    fun ownDevices(config: HavenConfig): List<MeshSendTarget> {
        // Linked devices belong to the account that linked them; the sender sends the owner's posts, so only the
        // owner's devices get them (Logen 2026-11-05).
        val owners = config.fipsMesh.devices.filter { MyDevicesRules.isOwners(it.linkedBy, config.ownerNpub) }
        val home = config.homeVaultNpub?.takeIf { h ->
            config.fipsMesh.devices.none { it.npub == h && !MyDevicesRules.isOwners(it.linkedBy, config.ownerNpub) }
        }
        val others = owners
            .filter { (it.role == DeviceRole.MAC || it.role == DeviceRole.PHONE) }
            .filter { it.npub in config.fipsPeers && it.npub != home && MyDevicesRules.isMeshNpub(it.npub) }
            .distinctBy { it.npub }
            .map { MeshSendTarget(it.npub, it.role) }
        // Macs before phones: a Mac keeps the full history, so it is the first copy worth having.
        return listOfNotNull(home?.let { MeshSendTarget(it, DeviceRole.HOME_VAULT) }) + others.sortedBy { if (it.role == DeviceRole.MAC) 0 else 1 }
    }

    /** Whether a device in this role is sent the owner's new notes and media: the mobile vault and Macs. */
    fun receivesSends(role: DeviceRole): Boolean = role == DeviceRole.HOME_VAULT || role == DeviceRole.MAC

    /**
     * After queueing one item on each lane: drain if any lane took it, so one full or broken lane
     * does not hold up the others, and say "full" if any did not (Tron, #1025).
     */
    fun afterQueueing(queued: List<Boolean>): Pair<Boolean, Boolean> = queued.any { it } to !queued.all { it }

    /** How a target is named in the card's problem line. */
    fun label(role: DeviceRole): String = when (role) {
        DeviceRole.MAC -> "Desktop vault · full history"
        DeviceRole.PHONE -> "Your other phone"
        else -> "Mobile vault · new posts"
    }

    /** The same, mid-sentence: "the mobile vault", "your desktop vault", "your other phone". */
    fun destination(role: DeviceRole): String = when (role) {
        DeviceRole.MAC -> "your desktop vault"
        DeviceRole.PHONE -> "your other phone"
        else -> "the mobile vault"
    }
}
