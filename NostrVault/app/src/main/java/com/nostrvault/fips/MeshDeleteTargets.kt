package com.nostrvault.fips

import com.nostrvault.relay.HavenConfig

/** A device of the owner's that Delete everywhere reaches over the mesh, and what to call it if the file stays. */
internal data class MeshDeleteTarget(val npub: String, val name: String) {
    /** How it is listed in a delete report: never the ingress URL, which carries a token. */
    val key: String get() = "fipsmesh://$npub/"
}

/**
 * Where Delete everywhere goes over the FIPS mesh: the devices [MeshSendTargets] sends the owner's
 * media to (the home vault, then each Mac in My Devices), whatever their Send media switch, since a
 * Mac holds what was uploaded on it too. A Mac with no public address was never reached before: its
 * copy stayed (Tod, 2026-10-31). "Delete from mirrors" keeps these copies. iOS reaches the same Mac
 * through `HavenConfig.blossomDeleteTargets`' FIPS address. Pure for the tests.
 */
internal object MeshDeleteTargets {
    fun of(config: HavenConfig, includeHomeVault: Boolean): List<MeshDeleteTarget> {
        if (!includeHomeVault) return emptyList()
        return MeshSendTargets.of(config).map { t ->
            // Its My Devices name, else "your Mac" / "the home vault": "Still on blossom.primal.net and your Mac".
            val name = config.fipsMesh.devices.firstOrNull { it.npub == t.npub }?.name?.trim().orEmpty()
            MeshDeleteTarget(t.npub, name.ifEmpty { MeshSendTargets.destination(t.role) })
        }
    }

    /**
     * Gone only when the DELETE was taken (or found nothing) and a HEAD right after says 404. A
     * device that does not list this phone answers on its mesh door, which has no DELETE and says
     * 404 to it: without the HEAD that read as deleted while the file stayed. [checkCode] null is
     * no answer, which proves nothing.
     */
    fun gone(deleteCode: Int, checkCode: Int?): Boolean =
        (deleteCode in 200..299 || deleteCode == 404) && checkCode == 404
}
