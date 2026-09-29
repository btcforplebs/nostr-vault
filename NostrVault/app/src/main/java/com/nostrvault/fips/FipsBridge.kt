package com.nostrvault.fips

import android.util.Log
import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable
import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.Json

/**
 * JNI bridge to the FIPS mesh (libnvfips.so, Rust; see fips-v2-android/).
 *
 * Upstream FIPS runs inside the app with an app-owned TUN, so no VpnService is
 * needed and the phone's one VPN slot stays free. Peers are introduced over
 * ordinary Nostr relays, with no transit server. Control plane only: packets
 * never cross JNI.
 *
 * The library is optional. It is built for arm64-v8a only, and a checkout
 * without it still builds. [isAvailable] is false in that case and every call
 * is a no-op, so the UI can say so plainly rather than crash.
 */
object FipsBridge {
    private const val TAG = "FipsBridge"

    /** False when this build has no libnvfips.so for the device's ABI. */
    @Volatile
    var isAvailable: Boolean = false
        private set

    private val json = Json { ignoreUnknownKeys = true; encodeDefaults = true }

    init {
        try {
            System.loadLibrary("nvfips")
            isAvailable = true
            Log.i(TAG, "libnvfips.so loaded")
        } catch (e: UnsatisfiedLinkError) {
            isAvailable = false
            Log.w(TAG, "FIPS mesh unavailable in this build: ${e.message}")
        }
    }

    /**
     * Start the node under [nsec], reachable only by [options].peers.
     *
     * Pass the *same* nsec every launch: the npub derived from it is the
     * address peers use. Returns 0 on success, negative on failure, and is
     * idempotent — starting a running node returns 0 without changing it.
     */
    fun start(nsec: String, options: FipsStartOptions = FipsStartOptions()): Int =
        if (!isAvailable) ERR_UNAVAILABLE else nativeStart(nsec, json.encodeToString(options))

    /** A fresh network identity to persist. Null if the library is absent. */
    fun generateNsec(): String? =
        if (!isAvailable) null else nativeGenerateNsec()

    /** Current state. Never null; reports [FipsStatus.stopped] when unavailable. */
    fun status(): FipsStatus {
        if (!isAvailable) return FipsStatus.stopped
        val raw = nativeStatusJSON() ?: return FipsStatus.stopped
        return parseStatus(raw)
    }

    internal fun parseStatus(raw: String): FipsStatus = try {
        json.decodeFromString<FipsStatus>(raw)
    } catch (e: Exception) {
        Log.w(TAG, "unparseable status: $raw")
        FipsStatus.stopped
    }

    internal fun encodeOptions(options: FipsStartOptions): String = json.encodeToString(options)

    /** Offer a local TCP port on the mesh. 0 on success, negative on failure. */
    fun export(localPort: Int): Int =
        if (!isAvailable) ERR_UNAVAILABLE else nativeExport(localPort)

    /**
     * Open a loopback listener proxying to [npub] over the mesh. Returns the
     * bound port, or negative on failure. Not implemented yet ([ERR_UNSUPPORTED]).
     */
    fun ingress(npub: String): Int =
        if (!isAvailable) ERR_UNAVAILABLE else nativeIngress(npub)

    fun stop() {
        if (isAvailable) nativeStop()
    }

    // Mirrors the ERR_* constants in fips-v2-android/src/lib.rs.
    const val ERR_CONFIG = -1
    const val ERR_UNSUPPORTED = -2
    const val ERR_NOT_RUNNING = -3
    const val ERR_ALREADY_EXPORTED = -4
    const val ERR_START = -5
    const val ERR_UNAVAILABLE = -100

    private external fun nativeStart(nsec: String, optionsJson: String): Int
    private external fun nativeGenerateNsec(): String?
    private external fun nativeStatusJSON(): String?
    private external fun nativeExport(localPort: Int): Int
    private external fun nativeIngress(npub: String): Int
    private external fun nativeStop()
}

/** What [FipsBridge.start] passes to the library, as JSON. */
@Serializable
data class FipsStartOptions(
    /** The only npubs allowed to reach this device. */
    val peers: List<String> = emptyList(),
    /** Advert and signaling relays. Empty keeps the library's defaults. */
    val relays: List<String> = emptyList(),
    @SerialName("udp_port") val udpPort: Int = 0,
    /** Offer private LAN addresses to peers. Needed when both are on one network. */
    val lan: Boolean = false,
)

/**
 * Snapshot of the node, as the library serialises it.
 *
 * `npub` and `address` are absent while stopped, so they are nullable rather
 * than defaulted to a blank string that would render as an empty address.
 */
@Serializable
data class FipsStatus(
    val running: Boolean = false,
    val npub: String? = null,
    val address: String? = null,
    @SerialName("uptime_s") val uptimeSeconds: Long = 0,
    /**
     * Ports actually offered on the mesh, as the library reports them.
     *
     * Read from the library rather than from the setting that asked for it:
     * the setting says what was wanted, and this says what a peer can reach.
     */
    val exported: List<Int> = emptyList(),
    /** Npubs of peers currently connected. */
    val peers: List<String> = emptyList(),
) {
    companion object {
        val stopped = FipsStatus()
    }
}
