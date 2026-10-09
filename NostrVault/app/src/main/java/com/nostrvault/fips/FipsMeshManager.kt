package com.nostrvault.fips

import android.util.Log
import com.nostrvault.data.local.ConfigStore
import com.nostrvault.data.local.CredentialStore
import com.nostrvault.di.ApplicationScope
import com.nostrvault.relay.HavenBridge
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.SharingStarted
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.map
import kotlinx.coroutines.flow.stateIn
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import javax.inject.Inject
import javax.inject.Singleton

/**
 * Owns the mesh endpoint's lifetime and its network identity.
 *
 * The identity is the whole point of this class. [FipsBridge.start] takes an
 * nsec and the npub derived from it *is* the address other people dial, so a
 * key that is not persisted means a new address every launch and nobody can
 * reach you twice. It lives in [CredentialStore] (AndroidKeyStore-backed),
 * separate from the account keys — the mesh address should be rotatable
 * without touching the social identity.
 */
@Singleton
class FipsMeshManager @Inject constructor(
    private val credentialStore: CredentialStore,
    private val configStore: ConfigStore,
    @ApplicationScope private val appScope: CoroutineScope,
) {

    private val _status = MutableStateFlow(FipsStatus.stopped)
    val status: StateFlow<FipsStatus> = _status.asStateFlow()

    /** Last failure, for the UI. Cleared by a successful start. */
    private val _lastError = MutableStateFlow<String?>(null)
    val lastError: StateFlow<String?> = _lastError.asStateFlow()

    /**
     * Whether the user has asked for the relay to be reachable on the mesh.
     *
     * Derived from the config file rather than held separately: the config is
     * loaded after this singleton is constructed, so a copy taken at
     * construction time would read false on every launch.
     */
    val shareRelay: StateFlow<Boolean> = configStore.config
        .map { it.fipsShareRelay }
        .stateIn(appScope, SharingStarted.Eagerly, false)

    /** Npubs allowed to reach this device, from the config file. */
    val peers: StateFlow<List<String>> = configStore.config
        .map { it.fipsPeers }
        .stateIn(appScope, SharingStarted.Eagerly, emptyList())

    /** False when this build ships no mesh library for the device's ABI. */
    val isAvailable: Boolean get() = FipsBridge.isAvailable

    /** Start on launch if the user left it on. */
    fun restoreIfEnabled(scope: CoroutineScope) {
        if (!configStore.config.value.fipsMeshEnabled) return
        scope.launch { start(persist = false) }
    }

    /**
     * Bind the endpoint, generating and persisting an identity the first time.
     *
     * [persist] is false when restoring a preference that is already stored —
     * writing it back on every launch would be a no-op with a disk write.
     */
    suspend fun start(persist: Boolean = true): Boolean = withContext(Dispatchers.IO) {
        if (!FipsBridge.isAvailable) {
            _lastError.value = "This build has no mesh library for your device."
            return@withContext false
        }

        val nsec = credentialStore.getMeshNsec() ?: FipsBridge.generateNsec()?.also {
            if (!credentialStore.storeMeshNsec(it)) {
                // Starting anyway would hand out an address that dies with the
                // process, which is worse than not starting: a peer would save
                // it and never reach us again.
                _lastError.value = "Could not save the mesh identity."
                return@withContext false
            }
        }
        if (nsec == null) {
            _lastError.value = "Could not create a mesh identity."
            return@withContext false
        }

        val rc = FipsBridge.start(nsec, startOptions())
        if (rc == 0 && configStore.config.value.fipsShareRelay) offerRelay()
        if (rc != 0) {
            Log.w(TAG, "FipsBridgeStartWithIdentity failed: $rc")
            _lastError.value = "The mesh endpoint did not start (code $rc)."
            refresh()
            return@withContext false
        }

        _lastError.value = null
        if (persist) configStore.updateAsync { it.copy(fipsMeshEnabled = true) }
        refresh()
        true
    }

    /**
     * Who may reach this device, and how.
     *
     * Only the npubs the user has added can connect: the library runs FIPS's
     * configured-only policy, so an empty list means nobody. LAN candidates are
     * shared because a friend is often on the same home network, where the
     * public address alone cannot connect the two; with configured-only, only
     * those friends ever see them.
     */
    private fun startOptions() = FipsStartOptions(
        peers = configStore.config.value.fipsPeers,
        lan = true,
    )

    /**
     * Replace the list of npubs allowed to reach this device.
     *
     * The library takes the list at start, so a running node is restarted to
     * apply it. The identity is persisted, so the address survives.
     */
    suspend fun setPeers(npubs: List<String>) = withContext(Dispatchers.IO) {
        val cleaned = npubs.map { it.trim() }.filter { it.startsWith("npub1") }.distinct()
        configStore.updateAsync { it.copy(fipsPeers = cleaned) }
        if (_status.value.running) {
            FipsBridge.stop()
            start(persist = false)
        }
        refresh()
    }

    /**
     * Offer this device's media to the mesh.
     *
     * The export is the relay's mesh port, which serves blob GET/HEAD only:
     * a mesh peer arrives from loopback, so it must never reach the relay
     * itself (NIP-F1). There is no un-export — the accept loop lives as long
     * as the endpoint does — which is why [setShareRelay] restarts the bridge
     * to withdraw rather than pretending a flag is enough.
     */
    private fun offerRelay() {
        val port = configStore.config.value.meshPort
        HavenBridge.setMeshServing(true)
        val rc = FipsBridge.export(port)
        if (rc != 0) Log.w(TAG, "FipsBridgeExport($port) failed: $rc")
    }

    /**
     * Turn relay sharing on or off.
     *
     * Being findable on the mesh and being reachable on it are separate
     * decisions, so this is a separate switch and it is off by default.
     */
    suspend fun setShareRelay(enabled: Boolean) = withContext(Dispatchers.IO) {
        configStore.updateAsync { it.copy(fipsShareRelay = enabled) }
        if (!_status.value.running) return@withContext
        if (enabled) {
            offerRelay()
        } else {
            // Withdrawing means dropping the endpoint. The identity is
            // persisted, so the address survives the restart.
            HavenBridge.setMeshServing(false)
            FipsBridge.stop()
            start(persist = false)
        }
        refresh()
    }

    suspend fun stop() = withContext(Dispatchers.IO) {
        HavenBridge.setMeshServing(false)
        FipsBridge.stop()
        configStore.updateAsync { it.copy(fipsMeshEnabled = false) }
        refresh()
    }

    /** Re-read the bridge. Polled: nothing ever calls back into the JVM. */
    suspend fun refresh() = withContext(Dispatchers.IO) {
        _status.value = FipsBridge.status()
    }

    private companion object {
        const val TAG = "FipsMeshManager"
    }
}
