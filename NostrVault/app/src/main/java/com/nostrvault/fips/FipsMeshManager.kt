package com.nostrvault.fips

import android.util.Log
import com.nostrvault.data.local.ConfigStore
import com.nostrvault.data.local.CredentialStore
import com.nostrvault.di.ApplicationScope
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

        val rc = FipsBridge.start(nsec)
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
     * Offer this device's relay port to the mesh.
     *
     * The Blossom server shares that port with the relay, so one export puts
     * both on the mesh. There is no un-export — the accept loop lives as long
     * as the endpoint does — which is why [setShareRelay] restarts the bridge
     * to withdraw rather than pretending a flag is enough.
     */
    private fun offerRelay() {
        val port = configStore.config.value.relayPort
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
            FipsBridge.stop()
            start(persist = false)
        }
        refresh()
    }

    suspend fun stop() = withContext(Dispatchers.IO) {
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
