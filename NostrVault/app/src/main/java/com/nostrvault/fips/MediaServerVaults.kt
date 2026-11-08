package com.nostrvault.fips

import com.nostrvault.relay.HavenConfig

/** One of the owner's vaults on Media Servers: listed in their 10063 or not, with "Add to my media servers". */
data class MediaServerVault(
    val npub: String,
    val title: String,
    /** "Mobile vault", "Desktop vault", or "On your mesh" for a listed entry this phone has no device for. */
    val kind: String,
    val listed: Boolean,
)

/**
 * The vaults Media Servers offers (Logen 2026-11-08): the owner's mobile vault and desktop vaults (Mac, Linux) in
 * My Devices, and any `fipsmesh://` entry already on their published list, so it can be taken off. Phones and the
 * browser vault never show up. Adding or taking one off is the owner's choice there, and only that Save publishes
 * it: linking or removing a vault in My Devices leaves the 10063 alone. Pure for the tests.
 */
object MediaServerVaults {
    const val MOBILE = "Mobile vault"
    const val DESKTOP = "Desktop vault"
    const val UNKNOWN = "On your mesh"

    fun rows(config: HavenConfig, published: List<String>): List<MediaServerVault> {
        val labels = config.fipsMesh.devices.associateBy { it.npub }
        val publishedMesh = published.mapNotNull { FipsMediaRouter.meshNpubIn(it) }.distinct()
        val add = config.serverListAddMesh.toSet()
        val drop = config.serverListDropMesh.toSet()
        fun listed(npub: String) = (npub in publishedMesh || npub in add) && npub !in drop
        val own = MeshSendTargets.of(config).map { t ->
            val kind = if (t.role == DeviceRole.MAC) DESKTOP else MOBILE
            MediaServerVault(t.npub, labels[t.npub]?.name?.trim().orEmpty().ifEmpty { kind }, kind, listed(t.npub))
        }
        val ownNpubs = own.map { it.npub }.toSet()
        // Already listed, but not a vault in My Devices: shown so it can be taken off. A phone or browser listed by
        // another app stays hidden, as Logen asked.
        val others = (publishedMesh + add).distinct()
            .filter { it !in ownNpubs }
            .filter { labels[it]?.role.let { r -> r != DeviceRole.PHONE && r != DeviceRole.BROWSER } }
            .map { npub ->
                val label = labels[npub]
                val kind = when (label?.role) { DeviceRole.MAC -> DESKTOP; DeviceRole.HOME_VAULT -> MOBILE; else -> UNKNOWN }
                MediaServerVault(npub, label?.name?.trim().orEmpty().ifEmpty { shortNpub(npub) }, kind, listed(npub))
            }
        return own + others
    }

    /** The pending lists after the owner taps Add ([list] true) or Take off on [npub]. */
    fun choose(config: HavenConfig, npub: String, list: Boolean): HavenConfig =
        if (list) config.copy(serverListAddMesh = (config.serverListAddMesh + npub).distinct(), serverListDropMesh = config.serverListDropMesh - npub)
        else config.copy(serverListAddMesh = config.serverListAddMesh - npub, serverListDropMesh = (config.serverListDropMesh + npub).distinct())

    private fun shortNpub(npub: String) = if (npub.length > 16) "${npub.take(10)}…${npub.takeLast(4)}" else npub
}
