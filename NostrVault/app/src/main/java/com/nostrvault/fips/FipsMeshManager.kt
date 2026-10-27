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
import kotlinx.coroutines.flow.distinctUntilChanged
import kotlinx.coroutines.flow.map
import kotlinx.coroutines.flow.stateIn
import kotlinx.coroutines.launch
import kotlinx.coroutines.sync.withLock
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

    /**
     * Start if the user left it on: on launch, and from the relay service, which is what brings
     * it back after a reboot. Both may ask; one start at a time, and none while it runs.
     */
    fun restoreIfEnabled(scope: CoroutineScope) {
        if (!configStore.config.value.fipsMeshEnabled || _status.value.running) return
        if (!restoring.compareAndSet(false, true)) return
        scope.launch {
            try {
                if (!FipsBridge.status().running) start(persist = false) else refresh()
            } finally {
                restoring.set(false)
            }
        }
    }

    private val restoring = java.util.concurrent.atomic.AtomicBoolean(false)

    // Both above init: its collector may run before the rest of the constructor.
    /** The allowlist the running engine started with; null before the first start. */
    @Volatile private var engineOwnDevices: List<String>? = null

    /** One restart at a time: setPeers and the My Devices watch can both ask. */
    private val restartLock = kotlinx.coroutines.sync.Mutex()

    init {
        // My Devices is the engine's allowlist and is fixed at start: a running engine restarts
        // when it changes. setPeers restarts on its own; this covers the home vault, which is
        // set from elsewhere (HomeVaultSender.setHomeVault).
        appScope.launch {
            configStore.config
                .map { MeshEnginePlan.ownDevices(it, _status.value.npub) }
                .distinctUntilChanged()
                .collect {
                    withContext(Dispatchers.IO) {
                        restartKeepingAllowance(onlyIf = {
                            engineOwnDevices != null &&
                                MeshEnginePlan.ownDevices(configStore.config.value, _status.value.npub) != engineOwnDevices
                        })
                    }
                }
        }
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

        // A read that failed is not "no key": minting then would change this
        // device's mesh address for every peer that saved it.
        val saved = try {
            credentialStore.readMeshNsec()
        } catch (e: Exception) {
            Log.w(TAG, "mesh identity unreadable: ${e.javaClass.simpleName}")
            _lastError.value = "Could not read the mesh identity."
            return@withContext false
        }
        val nsec = saved ?: FipsBridge.generateNsec()?.also {
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
        watch()
        true
    }

    private var watchJob: kotlinx.coroutines.Job? = null

    /**
     * Poll while the node runs, wherever the user is. The serve cap is
     * enforced in the library, but only [refresh] turns the share switch off
     * to match; left to the Mesh screen's own poll, the switch would stay on
     * and the next launch would share another full allowance (Tron, #471).
     */
    private fun watch() {
        // One poll at a time. Never cancel a running one: a restart from inside
        // its own refresh (the cap turning sharing off) would cancel the poll
        // mid-way and lose the message saying why.
        if (watchJob?.isActive == true) return
        watchJob = appScope.launch(Dispatchers.IO) {
            while (true) {
                kotlinx.coroutines.delay(WATCH_INTERVAL_MS)
                refresh()
                if (!_status.value.running) break
            }
        }
    }

    /**
     * Who may reach this device, and how: My Devices only, when there are any
     * ([MeshEnginePlan]). The library used to run open to anyone, so any npub
     * that sent an offer learned this phone's public and LAN addresses.
     */
    private fun startOptions(): FipsStartOptions {
        // What is left of this sharing session's allowance: neither a restart
        // for a peer or limit change nor an app launch hands out a fresh one.
        val config = configStore.config.value
        engineBase = config.fipsServedBytes
        engineGen++
        val options = MeshEnginePlan.options(config, _status.value.npub, remainingServeBytes(config.fipsServeLimitBytes, engineBase))
        engineOwnDevices = options.ownDevices
        return options
    }

    /**
     * What this sharing session had sent before the running engine started,
     * from the config file, so neither a restart nor an app launch hands out a
     * fresh allowance (Tron, #471). The engine's own count adds to it.
     */
    @Volatile private var engineBase = 0L

    /** Bumped whenever the engine (and so `engineBase`) is replaced. */
    @Volatile private var engineGen = 0L

    /** One reaction to a reached cap at a time; the Mesh screen polls too. */
    private val turningOffForCap = java.util.concurrent.atomic.AtomicBoolean(false)

    /**
     * Restart to apply start-time settings, keeping what was already served.
     * Skipped when the engine is not running or [onlyIf], checked under the lock, says no.
     */
    private suspend fun restartKeepingAllowance(onlyIf: () -> Boolean = { true }) = restartLock.withLock {
        if (!_status.value.running || !onlyIf()) return@withLock
        restartNow()
    }

    private suspend fun restartNow() {
        engineGen++  // a refresh reading the old engine now discards its count
        if (configStore.config.value.fipsShareRelay) {
            val served = engineBase + FipsBridge.status().visitorServedTx
            configStore.updateAsync { it.copy(fipsServedBytes = served) }
        }
        FipsBridge.stop()
        start(persist = false)
    }

    /** What one sharing session may send before it stops. Applies from the next start. */
    val serveLimitBytes: StateFlow<Long> = configStore.config
        .map { it.fipsServeLimitBytes }
        .stateIn(appScope, SharingStarted.Eagerly, 1L shl 30)

    /** The library takes the limit at start, so a running node restarts to apply it. */
    suspend fun setServeLimit(bytes: Long) = withContext(Dispatchers.IO) {
        configStore.updateAsync { it.copy(fipsServeLimitBytes = bytes) }
        if (_status.value.running) restartKeepingAllowance()
        refresh()
    }

    /**
     * Replace the list of npubs allowed to reach this device.
     *
     * The library takes the list at start, so a running node is restarted to
     * apply it. The identity is persisted, so the address survives.
     */
    suspend fun setPeers(npubs: List<String>) = withContext(Dispatchers.IO) {
        val cleaned = npubs.map { it.trim() }.filter { it.startsWith("npub1") }.distinct()
        configStore.updateAsync { it.copy(fipsPeers = cleaned) }
        if (_status.value.running) restartKeepingAllowance()
        refresh()
    }

    /** Finder relays and middle server, both read at start: a running node restarts to apply them. */
    suspend fun setAdvanced(relays: List<String>, middleServer: String) = withContext(Dispatchers.IO) {
        val cleaned = relays.map { it.trim() }.filter { it.isNotEmpty() }.distinct()
            // The defaults are stored as "none chosen", so a later change to them reaches this phone too.
            .takeUnless { it == FipsMeshSettings.DEFAULT_FINDER_RELAYS }.orEmpty()
        configStore.updateAsync { it.copy(fipsMesh = it.fipsMesh.copy(finderRelays = cleaned, middleServer = middleServer)) }
        if (_status.value.running) restartKeepingAllowance()
        refresh()
    }

    /**
     * Offer this device's media to the mesh.
     *
     * With no devices the export is the relay's mesh door (blob reads and
     * owner-signed writes only): a mesh peer arrives from loopback, so a
     * stranger must never reach the relay itself (NIP-F1). With My Devices
     * set, they get the relay port and the engine sends everyone else to the
     * door ([MeshEnginePlan]). There is no un-export — the accept loop lives as long
     * as the endpoint does — which is why [setShareRelay] restarts the bridge
     * to withdraw rather than pretending a flag is enough.
     */
    private fun offerRelay() {
        val port = MeshEnginePlan.sharePort(configStore.config.value, engineOwnDevices.orEmpty())
        // The door, for strangers (or for everyone when the engine is open).
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
    suspend fun setShareRelay(enabled: Boolean): Unit = withContext(Dispatchers.IO) {
        // Switching sharing starts a new session with a full allowance.
        configStore.updateAsync { it.copy(fipsShareRelay = enabled, fipsServedBytes = 0) }
        engineGen++
        engineBase = 0
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
    suspend fun refresh(): Unit = withContext(Dispatchers.IO) {
        // Base and count must belong to the same engine: read the base first and
        // drop the write if a restart swapped engines meanwhile (Tron, #471).
        val gen = engineGen
        val base = engineBase
        val status = FipsBridge.status()
        _status.value = status
        // Keep the session's count on disk as it grows, so an app restart
        // (Android kills background processes often) resumes it.
        if (status.running && configStore.config.value.fipsShareRelay && gen == engineGen) {
            servedToPersist(base, status.visitorServedTx, configStore.config.value.fipsServedBytes)
                ?.let { served -> configStore.updateAsync { it.copy(fipsServedBytes = served) } }
        }
        // The library already stopped sharing; turn the switch off to match, so
        // the next launch does not share again on its own.
        if (status.capReached && configStore.config.value.fipsShareRelay &&
            turningOffForCap.compareAndSet(false, true)
        ) {
            try {
                val mb = configStore.config.value.fipsServeLimitBytes shr 20
                val limit = if (mb >= 1024 && mb % 1024 == 0L) "${mb / 1024} GB" else "$mb MB"
                Log.i(TAG, "sharing off: serve limit $limit reached")
                setShareRelay(false)
                _lastError.value = "Sharing turned off: the mesh downloaded $limit from this phone, " +
                    "your limit for one session. Turn it on again to share more."
            } finally {
                turningOffForCap.set(false)
            }
        }
    }

    private companion object {
        const val TAG = "FipsMeshManager"
        // A limit that takes a gigabyte to reach needs no faster check.
        const val WATCH_INTERVAL_MS = 30_000L
    }
}

/**
 * What a restarted engine may still serve this session. Never 0: the library
 * reads 0 as "use the default", which would hand out a fresh allowance.
 */
internal fun remainingServeBytes(limit: Long, alreadyServed: Long): Long =
    (limit - alreadyServed).coerceAtLeast(1)

/** Writes of the served count are batched to this much new traffic. */
internal const val SERVED_PERSIST_STEP = 16L shl 20

/**
 * The session count to write, or null when it has not grown by a step yet.
 * `engineBase` is what the session had sent before this engine started.
 */
internal fun servedToPersist(engineBase: Long, engineServed: Long, persisted: Long): Long? {
    val served = engineBase + engineServed
    return if (served - persisted >= SERVED_PERSIST_STEP) served else null
}
