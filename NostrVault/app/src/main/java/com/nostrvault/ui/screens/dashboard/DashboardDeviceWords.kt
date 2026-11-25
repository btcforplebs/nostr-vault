package com.nostrvault.ui.screens.dashboard

import com.nostrvault.fips.MyDevice

/**
 * The words the dashboard's device cards share, pure for the tests: a row title that tells two devices with the same
 * name apart, and why the desktop Vault card has no fresh status.
 */
internal object DashboardDeviceWords {
    /**
     * Each device's title by npub: its own title, and when another row has the same one, the end of its npub too
     * ("Mac · x2we"), so two Macs read as two (Tao, nv-android acefaeee).
     */
    fun titles(devices: List<MyDevice>): Map<String, String> {
        val shared = devices.groupingBy { it.title.lowercase() }.eachCount().filterValues { it > 1 }.keys
        return devices.associate { d ->
            d.npub to if (d.title.lowercase() in shared) "${d.title} · ${d.npub.takeLast(SUFFIX)}" else d.title
        }
    }

    /** "3 of 3 on the mesh": the mesh link, not whether a desktop's Vault answers (the status card says that). */
    fun meshCount(devices: List<MyDevice>): String? =
        if (devices.isEmpty()) null else "${devices.count { it.inReach }} of ${devices.size} on the mesh"

    /**
     * Why the status card has nothing newer, from the engine's status error code (haven-go copyv2_status_client.go),
     * or null with none. Each code has its own words; anything else is the Vault not answering, which says nothing
     * about the mesh link "Your devices" counts.
     */
    fun statusReach(error: String?): String? = when (error) {
        null -> null
        "not_paired" -> "not caught up with yet"
        "not_found" -> "update it to see this"
        "auth_refused" -> "it didn't let this phone in"
        "bad_answer" -> "its answer couldn't be read"
        else -> "its Vault isn't answering"
    }

    private const val SUFFIX = 4
}
