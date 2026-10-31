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
    /** Where new photos go: "public" server, "mac", or "both". Stored only for now. */
    @SerialName("photos_go_to") val photosGoTo: String = PHOTOS_PUBLIC,
    /** Finder relays the mesh posts its address to. Empty means [DEFAULT_FINDER_RELAYS]. */
    @SerialName("finder_relays") val finderRelays: List<String> = emptyList(),
    /** Middle server: "public" (the fips1/fips2.iris.to seeds) or "none". None by default: Android never joined them. */
    @SerialName("middle_server") val middleServer: String = MIDDLE_NONE,
) {
    /** The relays the engine is started with: the user's, or the same three as iPhone and Mac. */
    val engineFinderRelays: List<String> get() = finderRelays.ifEmpty { DEFAULT_FINDER_RELAYS }

    companion object {
        const val PHOTOS_PUBLIC = "public"
        const val PHOTOS_MAC = "mac"
        const val PHOTOS_BOTH = "both"
        const val MIDDLE_PUBLIC = "public"
        const val MIDDLE_NONE = "none"

        /**
         * The finder relays every Nostr Vault starts its mesh with (iOS MeshDevicesLogic.defaultFinderRelays). Devices
         * find each other only through relays they share, so Android uses these too, not the library's own.
         */
        val DEFAULT_FINDER_RELAYS = listOf("wss://relay.nostr.net", "wss://nostr.bitcoiner.social", "wss://relay.btcforplebs.com")
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
    // Labels and lines as iOS MeshDeviceRole, so the three apps say the same thing.
    @SerialName("mac") MAC("Home vault · full history", "Keeps all your history. Syncs both ways."),
    @SerialName("phone") PHONE("Phone", "Another phone of yours on the mesh."),
    @SerialName("home_vault") HOME_VAULT("Home vault · new posts", "Keeps your new posts and media, and sends your notes on."),
    @SerialName("browser") BROWSER("Browser vault", "Gets your new notes while this app is open."),
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
    /** Its name, or its role when it has none (iOS MeshDevice.title). */
    val title: String get() = name.trim().ifBlank { role.label }
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
        npub: String, role: DeviceRole, name: String,
    ): Change? {
        if (!isMeshNpub(npub) || npub == ownNpub) return null
        val newHome = if (role == DeviceRole.HOME_VAULT) npub else homeVault.takeIf { it != npub }
        val kept = labels.filter { it.npub != npub }.map { if (it.npub == homeVault && newHome != homeVault) it.copy(role = DeviceRole.PHONE) else it }
        // Never seen until it is in reach: adding it is not seeing it.
        val label = FipsDevice(npub = npub, role = role, name = name.trim(), lastSeen = byNpubSeen(labels, npub))
        return Change(peers = (peers + npub).distinct(), homeVault = newHome, labels = kept + label)
    }

    private fun byNpubSeen(labels: List<FipsDevice>, npub: String) = labels.firstOrNull { it.npub == npub }?.lastSeen ?: 0

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

    /** A mesh address: a 63-character npub whose bech32 checksum holds, so a one-character typo is refused. */
    fun isMeshNpub(s: String): Boolean = Regex("^npub1[02-9ac-hj-np-z]{58}$").matches(s) && bech32ChecksumOk(s)

    private const val BECH32 = "qpzry9x8gf2tvdw0s3jn54khce6mua7l"

    /** BIP-173 checksum over the human part and the data, as every Nostr client checks an npub. */
    internal fun bech32ChecksumOk(s: String): Boolean {
        val sep = s.lastIndexOf('1')
        if (sep < 1) return false
        val hrp = s.substring(0, sep)
        val data = s.substring(sep + 1).map { BECH32.indexOf(it).takeIf { i -> i >= 0 } ?: return false }
        val values = hrp.map { it.code shr 5 } + 0 + hrp.map { it.code and 31 } + data
        var chk = 1
        val gen = intArrayOf(0x3b6a57b2, 0x26508e6d, 0x1ea119fa, 0x3d4233dd, 0x2a1462b3)
        for (v in values) {
            val top = chk ushr 25
            chk = ((chk and 0x1ffffff) shl 5) xor v
            for (i in 0 until 5) if ((top shr i) and 1 == 1) chk = chk xor gen[i]
        }
        return chk == 1
    }

    /** A finder relay a user may add: wss://, a host, nothing else. */
    fun isFinderRelay(s: String): Boolean = Regex("^wss://[a-z0-9.-]+(:\\d{1,5})?(/\\S*)?$").matches(s.trim().lowercase())

    data class Change(val peers: List<String>, val homeVault: String?, val labels: List<FipsDevice>)
}
