package com.nostrvault.fips

import android.util.Log
import com.nostrvault.relay.HavenBridge
import com.nostrvault.relay.HavenConfig

/**
 * Hands the engine this device's mesh npub and My Devices (SetMeshDevicesC, docs/MESH_COPY_V2_CONTRACT.md §2): only
 * these devices' mesh keys may start a copy or use Blossom over the mesh here, and a device that leaves the set loses
 * its copy tokens at once. Pushed when the relay starts and after every My Devices change ([FipsMeshManager]); the same
 * owner's devices the mesh engine gets as `own_devices` ([MeshEnginePlan.ownDevices]). Twin of Apple's
 * `MeshDeviceSetSync.swift` (#1803).
 */
object MeshDeviceSetSync {
    private const val TAG = "MeshDeviceSet"

    /** The set for [config]: the owner's devices with their roles (the home vault's if unlabelled, else a phone). */
    fun devices(config: HavenConfig, ownNpub: String?): List<MeshKeyAuth.Device> =
        MeshEnginePlan.ownDevices(config, ownNpub).map { npub ->
            val role = config.fipsMesh.devices.firstOrNull { it.npub == npub }?.role
                ?: if (npub == config.homeVaultNpub?.trim()) DeviceRole.HOME_VAULT else DeviceRole.PHONE
            MeshKeyAuth.Device(npub, role)
        }

    /** The JSON for [config], or null when this device has no mesh npub yet. */
    fun json(config: HavenConfig, ownNpub: String?): String? = MeshKeyAuth.deviceSet(ownNpub, devices(config, ownNpub))

    /**
     * Push the set. [statusNpub] is the running engine's npub; without it the key is read (never made: asking the mesh
     * engine for one would make a key on a device that never used the mesh). None yet: the engine keeps its set.
     */
    fun push(config: HavenConfig, statusNpub: String?) {
        if (!HavenBridge.isLoaded) return
        val own = statusNpub ?: MeshKeySigner.npub()
        val body = json(config, own) ?: return
        val rc = runCatching { HavenBridge.setMeshDevices(body) }.getOrDefault(-1)
        if (rc != 0) Log.e(TAG, "the engine did not take My Devices ($rc)")
    }
}
