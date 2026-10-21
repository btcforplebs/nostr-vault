package com.nostrvault.fips

import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable

/**
 * What the FIPS Mesh screen keeps beyond the mesh's own switches (RESEARCH/NV_FIPS_SETTINGS_DESIGN.md):
 * names and roles for My Devices, the Share With Others choices, and Advanced. Lives in
 * [com.nostrvault.relay.HavenConfig.fipsMesh]; every field has a default, so an older config reads as today.
 */
@Serializable
data class FipsMeshSettings(
    /** Name, role and switches per device, by mesh npub. The list itself is fipsPeers plus the home vault. */
    val devices: List<FipsDevice> = emptyList(),
    /** Who can view this vault while it is shared: "devices" (only my devices) or "anyone" (anyone on the mesh). */
    @SerialName("who_can_view") val whoCanView: String = WHO_DEVICES,
    /** List this phone's mesh address in the owner's media servers while it is shared. */
    @SerialName("list_in_media_servers") val listInMediaServers: Boolean = false,
    /** Where new photos go: "public" server, "mac", or "both". Stored only for now. */
    @SerialName("photos_go_to") val photosGoTo: String = PHOTOS_PUBLIC,
    /** Finder relays the mesh posts its address to. Empty keeps the library's built-in ones. */
    @SerialName("finder_relays") val finderRelays: List<String> = emptyList(),
    /** Middle server: "public" (fips1/fips2.iris.to), "own" ([middleServerOwn]) or "none". */
    @SerialName("middle_server") val middleServer: String = MIDDLE_NONE,
    @SerialName("middle_server_own") val middleServerOwn: String = "",
) {
    companion object {
        const val WHO_DEVICES = "devices"
        const val WHO_ANYONE = "anyone"
        const val PHOTOS_PUBLIC = "public"
        const val PHOTOS_MAC = "mac"
        const val PHOTOS_BOTH = "both"
        const val MIDDLE_PUBLIC = "public"
        const val MIDDLE_OWN = "own"
        const val MIDDLE_NONE = "none"
    }
}

@Serializable
data class FipsDevice(
    val npub: String,
    val role: DeviceRole = DeviceRole.PHONE,
    val name: String = "",
    @SerialName("send_notes") val sendNotes: Boolean = true,
    @SerialName("send_media") val sendMedia: Boolean = true,
    /** Unix seconds this device was last in reach, or 0 when never seen. */
    @SerialName("last_seen") val lastSeen: Long = 0,
)

@Serializable
enum class DeviceRole(val label: String, val blurb: String) {
    @SerialName("mac") MAC("Vault on Mac", "Keeps your full history. Syncs both ways."),
    @SerialName("phone") PHONE("Phone", "Another phone with your vault. Syncs both ways."),
    @SerialName("home_vault") HOME_VAULT("Home vault", "Gets your posts and media and passes your posts on to the regular relays."),
    @SerialName("browser") BROWSER("Browser page", "A Nostr Vault page open in a browser. Reaches your vault while it is open."),
}

/** One row of My Devices. */
data class MyDevice(
    val npub: String,
    val role: DeviceRole,
    val name: String,
    val inReach: Boolean,
    val lastSeen: Long,
    val sendNotes: Boolean,
    val sendMedia: Boolean,
) {
    val title: String get() = name.ifBlank { npub.take(12) + "…" + npub.takeLast(6) }
}

/**
 * The rules behind My Devices, pure for the tests. One list both ways (Logen, 2026-10-21): every device in it may
 * reach this phone (it is the mesh's allowlist, fipsPeers), and the one marked Home vault also gets this phone's posts
 * and media (homeVaultNpub).
 */
object MyDevicesRules {
    /** The list: allowed peers, plus a home vault that is not among them yet, with names and roles from [labels]. */
    fun list(peers: List<String>, homeVault: String?, labels: List<FipsDevice>, connected: List<String>): List<MyDevice> {
        val byNpub = labels.associateBy { it.npub }
        return (peers + listOfNotNull(homeVault)).distinct().map { npub ->
            val label = byNpub[npub]
            MyDevice(
                npub = npub,
                role = if (npub == homeVault) DeviceRole.HOME_VAULT else label?.role?.takeIf { it != DeviceRole.HOME_VAULT } ?: DeviceRole.PHONE,
                name = label?.name.orEmpty(),
                inReach = npub in connected,
                lastSeen = label?.lastSeen ?: 0,
                sendNotes = label?.sendNotes ?: true,
                sendMedia = label?.sendMedia ?: true,
            )
        }
    }

    /** "On · 3 of 4 devices in reach", "On", "Off". */
    fun statusLine(running: Boolean, devices: List<MyDevice>): String = when {
        !running -> "Off"
        devices.isEmpty() -> "On"
        else -> "On · ${devices.count { it.inReach }} of ${devices.size} ${if (devices.size == 1) "device" else "devices"} in reach"
    }

    /**
     * Adding a device: the new allowlist, the home vault after it, and the labels. Picking Home vault for a new device
     * moves that role from the old one, which stays in the list as a phone. -> null when [npub] is not a mesh address
     * or is this phone's own.
     */
    fun add(
        peers: List<String>, homeVault: String?, labels: List<FipsDevice>, ownNpub: String?,
        npub: String, role: DeviceRole, name: String, now: Long = 0,
    ): Change? {
        if (!isMeshNpub(npub) || npub == ownNpub) return null
        val newHome = if (role == DeviceRole.HOME_VAULT) npub else homeVault.takeIf { it != npub }
        val kept = labels.filter { it.npub != npub }.map { if (it.npub == homeVault && newHome != homeVault) it.copy(role = DeviceRole.PHONE) else it }
        val label = FipsDevice(npub = npub, role = role, name = name.trim(), lastSeen = now)
        return Change(peers = (peers + npub).distinct(), homeVault = newHome, labels = kept + label)
    }

    /** Removing a device: out of the allowlist, its label gone, and no home vault if it was that. */
    fun remove(peers: List<String>, homeVault: String?, labels: List<FipsDevice>, npub: String): Change =
        Change(peers = peers - npub, homeVault = homeVault.takeIf { it != npub }, labels = labels.filter { it.npub != npub })

    /** Labels with lastSeen bumped for every device in reach now. Same list when nothing changed. */
    fun seen(labels: List<FipsDevice>, devices: List<String>, connected: List<String>, now: Long): List<FipsDevice> {
        val reached = devices.filter { it in connected }
        if (reached.isEmpty()) return labels
        val byNpub = labels.associateBy { it.npub }.toMutableMap()
        for (npub in reached) byNpub[npub] = (byNpub[npub] ?: FipsDevice(npub)).copy(lastSeen = now)
        return labels.map { byNpub.getValue(it.npub) } + reached.filter { r -> labels.none { it.npub == r } }.map { byNpub.getValue(it) }
    }

    /** "Now", "5 min ago", "2 h ago", "3 d ago", "Never". */
    fun lastSeenText(lastSeen: Long, inReach: Boolean, now: Long): String {
        if (inReach) return "Now"
        if (lastSeen <= 0) return "Never"
        val s = (now - lastSeen).coerceAtLeast(0)
        return when {
            s < 60 -> "Just now"
            s < 3600 -> "${s / 60} min ago"
            s < 86_400 -> "${s / 3600} h ago"
            else -> "${s / 86_400} d ago"
        }
    }

    /** A mesh address: a bech32 npub, 63 characters. */
    fun isMeshNpub(s: String): Boolean = Regex("^npub1[02-9ac-hj-np-z]{58}$").matches(s)

    /** A finder relay a user may add: wss://, a host, nothing else. */
    fun isFinderRelay(s: String): Boolean = Regex("^wss://[a-z0-9.-]+(:\\d{1,5})?(/\\S*)?$").matches(s.trim().lowercase())

    data class Change(val peers: List<String>, val homeVault: String?, val labels: List<FipsDevice>)
}
